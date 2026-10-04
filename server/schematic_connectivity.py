"""
Connectivity check for one schematic sheet, computed from get_schematic_objects
output. Pure Python (no Altium calls) so it can be unit-tested offline.

Connection rules (Altium's):
- A wire END touching another wire anywhere connects them (a T-join; Altium
  draws that dot itself and does not store it). Wires that merely cross connect
  only if a junction object sits on the crossing.
- A pin connects at its connection point (hot end), also when the hot end lands
  in the MIDDLE of a wire. Designers do that on purpose (e.g. crystal load caps),
  but it is also how a wire routed across a part shorts it - so it is reported
  as info, and a two-pin part with both pins on one net as an error.
- Net labels, power ports, ports (either end) and off-sheet connectors name what
  they touch; equal names are the same net. A No ERC marker marks an end or pin
  as intentionally unconnected.
Buses and bus entries are not traced.
"""
from collections import defaultdict

TOL = 0.5  # mils


def _same(a, b):
    return abs(a[0] - b[0]) <= TOL and abs(a[1] - b[1]) <= TOL


def _on_segment(p, a, b):
    """True if p lies on segment a-b (inclusive of the ends)."""
    if not (min(a[0], b[0]) - TOL <= p[0] <= max(a[0], b[0]) + TOL and
            min(a[1], b[1]) - TOL <= p[1] <= max(a[1], b[1]) + TOL):
        return False
    cross = (b[0] - a[0]) * (p[1] - a[1]) - (b[1] - a[1]) * (p[0] - a[0])
    length = max(abs(b[0] - a[0]), abs(b[1] - a[1]), 1)
    return abs(cross) / length <= TOL


def _segment_intersection(a, b, c, d):
    """Intersection point of segments a-b and c-d, or None (parallel/overlap ignored)."""
    den = (b[0] - a[0]) * (d[1] - c[1]) - (b[1] - a[1]) * (d[0] - c[0])
    if abs(den) < 1e-9:
        return None
    t = ((c[0] - a[0]) * (d[1] - c[1]) - (c[1] - a[1]) * (d[0] - c[0])) / den
    u = ((c[0] - a[0]) * (b[1] - a[1]) - (c[1] - a[1]) * (b[0] - a[0])) / den
    if -1e-9 <= t <= 1 + 1e-9 and -1e-9 <= u <= 1 + 1e-9:
        return (round(a[0] + t * (b[0] - a[0]), 3), round(a[1] + t * (b[1] - a[1]), 3))
    return None


class _UnionFind:
    def __init__(self):
        self.parent = {}

    def find(self, x):
        self.parent.setdefault(x, x)
        while self.parent[x] != x:
            self.parent[x] = self.parent[self.parent[x]]
            x = self.parent[x]
        return x

    def union(self, a, b):
        self.parent[self.find(a)] = self.find(b)


class _Wire:
    def __init__(self, index, vertices):
        self.index = index
        self.points = [(v["x"], v["y"]) for v in vertices]
        self.ends = [self.points[0], self.points[-1]] if self.points else []
        self.segments = list(zip(self.points, self.points[1:]))

    def touches(self, p):
        return any(_on_segment(p, a, b) for a, b in self.segments)

    def is_end(self, p):
        return any(_same(p, e) for e in self.ends)


def analyze_connectivity(sheet: dict) -> dict:
    """Return {summary, issues, nets, unconnected_pins} for one sheet's objects."""
    wires = [_Wire(i, w.get("vertices", [])) for i, w in enumerate(sheet.get("wires", []))]
    wires = [w for w in wires if len(w.points) >= 2]
    junctions = [(j["x"], j["y"]) for j in sheet.get("junctions", [])]

    pins = []  # (key, designator, point)
    for comp in sheet.get("components", []):
        for pin in comp.get("pins", []):
            pins.append((f'{comp["designator"]}.{pin["number"]}', comp["designator"], (pin["x"], pin["y"])))

    # Multi-part parts appear once per part under the same designator.
    pin_count = defaultdict(int)
    for comp in sheet.get("components", []):
        pin_count[comp["designator"]] += len(comp.get("pins", []))

    named = []  # (kind, name, point); only kinds in REPORT_FLOATING are checked for touching
    for label in sheet.get("net_labels", []):
        named.append(("net_label", label["net_name"], (label["x"], label["y"])))
    for port in sheet.get("power_ports", []):
        named.append(("power_port", port["net_name"], (port["x"], port["y"])))
    for port in sheet.get("ports", []):
        named.append(("port", port["name"], (port["x"], port["y"])))
        if "x2" in port:
            named.append(("port", port["name"], (port["x2"], port["y2"])))
    for conn in sheet.get("off_sheet_connectors", []):
        named.append(("off_sheet_connector", conn["net_name"], (conn["x"], conn["y"])))
    no_erc = [(m["x"], m["y"]) for m in sheet.get("no_erc", [])]

    uf = _UnionFind()
    issues = []

    def issue(kind, severity, message, point=None, **extra):
        entry = {"type": kind, "severity": severity, "message": message}
        if point is not None:
            entry["x"], entry["y"] = point
        entry.update(extra)
        issues.append(entry)

    # Wire to wire: T-joins, crossings with a junction.
    for i, w1 in enumerate(wires):
        uf.find(("wire", w1.index))
        for w2 in wires[i + 1:]:
            joined = any(other.touches(end) for this, other in ((w1, w2), (w2, w1)) for end in this.ends)
            if not joined:
                for a, b in w1.segments:
                    for c, d in w2.segments:
                        x = _segment_intersection(a, b, c, d)
                        if x and any(_same(x, j) for j in junctions):
                            joined = True
            if joined:
                uf.union(("wire", w1.index), ("wire", w2.index))

    # Pins.
    pin_touch = defaultdict(list)
    for key, des, p in pins:
        uf.find(("pin", key))
        for w in wires:
            if w.touches(p):
                uf.union(("pin", key), ("wire", w.index))
                pin_touch[key].append(w.index)
                if not w.is_end(p):
                    issue("wire_through_pin", "info",
                          f"A wire runs through pin {key}'s connection point and continues, so the pin is "
                          f"connected to it. Fine if intended; a short if the wire was meant to pass by",
                          p, pin=key)
    for i, (k1, _, p1) in enumerate(pins):
        for k2, _, p2 in pins[i + 1:]:
            if _same(p1, p2):
                uf.union(("pin", k1), ("pin", k2))
                pin_touch[k1].append("pin")
                pin_touch[k2].append("pin")

    # Net labels and power ports.
    for kind, name, p in named:
        node = ("net", name)
        attached = False
        for w in wires:
            if w.touches(p):
                uf.union(node, ("wire", w.index))
                attached = True
        for key, _, pp in pins:
            if _same(p, pp):
                uf.union(node, ("pin", key))
                pin_touch[key].append(kind)
                attached = True
        if not attached and kind in ("net_label", "power_port"):
            uf.find(node)
            issue(f"floating_{kind}", "warning",
                  f"{kind.replace('_', ' ').capitalize()} '{name}' does not touch a wire or pin, so it names nothing", p,
                  net_name=name)

    # Dangling wire ends.
    anchors = [p for _, _, p in pins] + [p for _, _, p in named] + junctions + no_erc
    for e in sheet.get("bus_entries", []):
        anchors += [(e["x1"], e["y1"]), (e["x2"], e["y2"])]
    for w in wires:
        for end in w.ends:
            if any(_same(end, a) for a in anchors):
                continue
            if any(o is not w and o.touches(end) for o in wires):
                continue
            issue("dangling_wire_end", "warning", "Wire end is not connected to anything", end)

    # Nets.
    groups = defaultdict(lambda: {"pins": [], "names": set()})
    for key, _, _ in pins:
        groups[uf.find(("pin", key))]["pins"].append(key)
    for _, name, _ in named:
        groups[uf.find(("net", name))]["names"].add(name)

    nets, unconnected = [], []
    for g in groups.values():
        if not g["pins"]:
            continue
        if len(g["pins"]) == 1 and not g["names"] and not pin_touch.get(g["pins"][0]):
            pin_point = next(p for k, _, p in pins if k == g["pins"][0])
            if not any(_same(pin_point, m) for m in no_erc):
                unconnected.append(g["pins"][0])
            continue
        names = sorted(g["names"])
        nets.append({"name": names[0] if names else None, "pins": sorted(g["pins"])})
        if len(names) > 1:
            issue("net_name_conflict", "warning",
                  f"One net carries several names: {', '.join(names)}", names=names)
        by_part = defaultdict(list)
        for key in g["pins"]:
            by_part[key.rsplit(".", 1)[0]].append(key)
        for des, keys in by_part.items():
            if len(keys) > 1:
                net = names[0] if names else "unnamed"
                if pin_count.get(des) == 2:
                    issue("component_pins_shorted", "error",
                          f"Both pins of two-pin part {des} are on the same net ({net}): it is shorted",
                          pins=sorted(keys))
                else:
                    issue("component_pins_shorted", "info",
                          f"Pins {', '.join(sorted(keys))} of {des} share net {net} "
                          f"(normal for e.g. multiple GND pins; check if not intended)", pins=sorted(keys))
    nets.sort(key=lambda n: (n["name"] is None, n["name"] or "", n["pins"]))

    severities = [i["severity"] for i in issues]
    return {
        "sheet": sheet.get("sheet"),
        "summary": {
            "errors": severities.count("error"),
            "warnings": severities.count("warning"),
            "info": severities.count("info"),
            "nets": len(nets),
            "unconnected_pins": len(unconnected),
        },
        "issues": issues,
        "nets": nets,
        "unconnected_pins": sorted(unconnected),
    }
