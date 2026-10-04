"""
Layout (readability) check for one schematic sheet, computed from
get_schematic_objects output. Pure Python (no Altium calls) so it can be
unit-tested offline. Complements schematic_connectivity, which checks wiring.

Boxes are [left, bottom, right, top] in mils. Text boxes come from Altium and
fit the drawn text closely, so neighbouring labels routinely share an edge;
every overlap test allows a small tolerance before reporting.
"""
from itertools import combinations

BODY_TOL = 5    # mils a body may touch / be touched without counting
TEXT_TOL = 3    # mils of slack for text boxes


def _overlap(a, b, tol):
    """Overlap box of a and b if they overlap by more than tol on both axes."""
    left, right = max(a[0], b[0]), min(a[2], b[2])
    bottom, top = max(a[1], b[1]), min(a[3], b[3])
    if right - left > tol and top - bottom > tol:
        return [left, bottom, right, top]
    return None


def _shrink(box, d):
    return [box[0] + d, box[1] + d, box[2] - d, box[3] - d]


def _area(box):
    return max(0, box[2] - box[0]) * max(0, box[3] - box[1])


def _center(box):
    return (round((box[0] + box[2]) / 2), round((box[1] + box[3]) / 2))


def _segment_in_box(p, q, box):
    """Length of segment p-q inside box (Liang-Barsky clip); 0 if it misses."""
    x0, y0 = p
    dx, dy = q[0] - p[0], q[1] - p[1]
    t0, t1 = 0.0, 1.0
    for edge_p, edge_q in ((-dx, x0 - box[0]), (dx, box[2] - x0), (-dy, y0 - box[1]), (dy, box[3] - y0)):
        if edge_p == 0:
            if edge_q < 0:
                return 0.0
            continue
        r = edge_q / edge_p
        if edge_p < 0:
            t0 = max(t0, r)
        else:
            t1 = min(t1, r)
        if t0 > t1:
            return 0.0
    return (t1 - t0) * (dx * dx + dy * dy) ** 0.5


def _collinear_overlap(a, b, c, d):
    """Length two axis-aligned segments a-b and c-d share, else 0."""
    if a[1] == b[1] == c[1] == d[1]:
        lo, hi = max(min(a[0], b[0]), min(c[0], d[0])), min(max(a[0], b[0]), max(c[0], d[0]))
        return max(0, hi - lo)
    if a[0] == b[0] == c[0] == d[0]:
        lo, hi = max(min(a[1], b[1]), min(c[1], d[1])), min(max(a[1], b[1]), max(c[1], d[1]))
        return max(0, hi - lo)
    return 0


def _title_block(sheet):
    """The largest drawing graphic in the bottom-right quarter: the title block's outer
    frame (same rule as sch_create_sheet). Logos or notes drawn nearby are not part of it."""
    info = sheet.get("sheet_info", {})
    sx, sy = info.get("sheet_size_x", 0), info.get("sheet_size_y", 0)
    boxes = [g["bbox"] for g in sheet.get("drawing_graphics", [])
             if sx and g["bbox"][0] >= sx / 2 and g["bbox"][3] <= sy / 2]
    return max(boxes, key=_area) if boxes else None


def analyze_layout(sheet: dict) -> dict:
    """Return {summary, issues} describing readability problems on one sheet."""
    issues = []

    def issue(kind, severity, message, box=None, point=None, **extra):
        entry = {"type": kind, "severity": severity, "message": message}
        if box is not None:
            entry["x"], entry["y"] = _center(box)
        elif point is not None:
            entry["x"], entry["y"] = point
        entry.update(extra)
        issues.append(entry)

    info = sheet.get("sheet_info", {})
    sheet_box = [0, 0, info.get("sheet_size_x", 0), info.get("sheet_size_y", 0)]
    grid = info.get("snap_grid") or 50
    title = _title_block(sheet)

    def in_title(x, y):
        # By anchor point: a long "=Parameter" value can spill past the box.
        return title is not None and title[0] - 10 <= x <= title[2] + 10 and title[1] - 10 <= y <= title[3] + 10

    # Bodies.
    bodies = [(c["designator"], c["body"]) for c in sheet.get("components", []) if c.get("body")]

    # Texts: (label, box, owner designator or None, kind).
    texts = []
    for c in sheet.get("components", []):
        for name, t in c.get("text", {}).items():
            if t.get("visible") and t.get("bbox") and _area(t["bbox"]) > 0:
                texts.append((f'{c["designator"]} {name}', t["bbox"], c["designator"], "component_text"))
    for t in sheet.get("text_labels", []):
        if t.get("bbox") and _area(t["bbox"]) > 0 and not in_title(t["x"], t["y"]):
            texts.append((f'note "{t["text"]}"', t["bbox"], None, "note"))
    for n in sheet.get("net_labels", []):
        if n.get("bbox"):
            texts.append((f'net label "{n["net_name"]}"', n["bbox"], None, "net_label"))
    for p in sheet.get("power_ports", []):
        if p.get("bbox"):
            texts.append((f'power port "{p["net_name"]}"', p["bbox"], None, "power_port"))
    for p in sheet.get("ports", []):
        if p.get("bbox"):
            texts.append((f'port "{p["name"]}"', p["bbox"], None, "port"))

    segments = []  # (wire index, p, q)
    for i, w in enumerate(sheet.get("wires", [])):
        pts = [(v["x"], v["y"]) for v in w.get("vertices", [])]
        segments += [(i, a, b) for a, b in zip(pts, pts[1:])]

    # Errors: overlapping bodies, wires through bodies.
    for (d1, b1), (d2, b2) in combinations(bodies, 2):
        box = _overlap(b1, b2, BODY_TOL)
        if box:
            # Staggered parts (e.g. test points) often just touch; only a real collision is an error.
            severe = min(box[2] - box[0], box[3] - box[1]) >= 20
            issue("body_overlap", "error" if severe else "warning",
                  f"{d1} and {d2} {'overlap' if severe else 'touch'}", box, components=[d1, d2])
    for des, body in bodies:
        inner = _shrink(body, BODY_TOL)
        for wi, a, b in segments:
            if _segment_in_box(a, b, inner) > 0:
                issue("wire_crosses_body", "error",
                      f"A wire runs across the body of {des} (wires should end at pins, not cross parts)",
                      _overlap(inner, [min(a[0], b[0]), min(a[1], b[1]), max(a[0], b[0]), max(a[1], b[1])], -1)
                      or inner, component=des)
                break

    # Warnings: text collisions.
    for (n1, b1, o1, k1), (n2, b2, o2, k2) in combinations(texts, 2):
        box = _overlap(b1, b2, TEXT_TOL)
        if box:
            issue("text_overlap", "warning", f"{n1} overlaps {n2}", box, objects=[n1, n2])
    for name, box, owner, kind in texts:
        if kind in ("net_label", "power_port", "port"):
            continue  # these sit on wires by design
        inner = _shrink(box, TEXT_TOL)
        for wi, a, b in segments:
            if _segment_in_box(a, b, inner) > 0:
                issue("text_over_wire", "warning", f"A wire runs through {name}", inner, object=name)
                break
    for name, box, owner, kind in texts:
        for des, body in bodies:
            if des == owner:
                continue  # a part's own designator may sit inside its body (ICs)
            ov = _overlap(box, body, TEXT_TOL)
            if ov:
                issue("text_over_body", "warning", f"{name} overlaps the body of {des}", ov, object=name, component=des)

    # Warnings: wires drawn on top of each other.
    for (i1, a, b), (i2, c, d) in combinations(segments, 2):
        if i1 != i2 and _collinear_overlap(a, b, c, d) > 0:
            issue("wire_overlap", "warning",
                  "Two wires overlap along a stretch; it looks like one wire and hides how they connect",
                  [min(a[0], b[0], c[0], d[0]), min(a[1], b[1], c[1], d[1]),
                   max(a[0], b[0], c[0], d[0]), max(a[1], b[1], c[1], d[1])])

    # Warnings: placement on the sheet.
    placed = [(des, body) for des, body in bodies]
    placed += [(name, box) for name, box, owner, kind in texts]
    for i, w in enumerate(sheet.get("wires", [])):
        xs = [v["x"] for v in w["vertices"]]
        ys = [v["y"] for v in w["vertices"]]
        placed.append((f"wire {i + 1}", [min(xs), min(ys), max(xs), max(ys)]))
    for name, box in placed:
        if sheet_box[2] and (box[0] < 0 or box[1] < 0 or box[2] > sheet_box[2] or box[3] > sheet_box[3]):
            issue("off_sheet", "warning", f"{name} is partly outside the sheet", box, object=name)
        elif title and _overlap(box, title, TEXT_TOL):
            issue("in_title_block", "warning", f"{name} overlaps the title block", box, object=name)

    # Warnings: connection points off the snap grid.
    points = []
    for c in sheet.get("components", []):
        for p in c.get("pins", []):
            points.append((f'{c["designator"]}.{p["number"]}', (p["x"], p["y"])))
    for i, w in enumerate(sheet.get("wires", [])):
        points += [(f"wire {i + 1} vertex", (v["x"], v["y"])) for v in w["vertices"]]
    for key in ("power_ports", "net_labels", "junctions", "ports"):
        for o in sheet.get(key, []):
            points.append((f'{key[:-1].replace("_", " ")} {o.get("net_name") or o.get("name") or ""}'.strip(),
                           (o["x"], o["y"])))
    for name, (x, y) in points:
        if round(x) % grid or round(y) % grid:
            issue("off_grid", "warning",
                  f"{name} at ({x}, {y}) is off the {grid}-mil grid; connections there are easy to miss",
                  point=(x, y), object=name)

    # Info: diagonal wires.
    for wi, a, b in segments:
        if a[0] != b[0] and a[1] != b[1]:
            issue("diagonal_wire", "info", "Diagonal wire segment", point=a)

    severities = [i["severity"] for i in issues]
    return {
        "sheet": sheet.get("sheet"),
        "summary": {
            "errors": severities.count("error"),
            "warnings": severities.count("warning"),
            "info": severities.count("info"),
        },
        "title_block": title,
        "issues": issues,
    }
