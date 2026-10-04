"""
Offline tests for schematic_layout.analyze_layout (no Altium needed).

Run: python server/tests/test_schematic_layout.py
"""
import os
import sys
import unittest

sys.path.insert(0, os.path.abspath(os.path.join(os.path.dirname(__file__), '..')))

from schematic_layout import analyze_layout

SHEET_INFO = {"sheet_size_x": 9500, "sheet_size_y": 7500, "snap_grid": 50}
TITLE_FRAME = {"object_id": 18, "bbox": [5690, 190, 9310, 1060]}


def part(des, body, texts=None, pins=()):
    """Component with a body box and optional {name: bbox} visible texts."""
    return {"designator": des, "body": body,
            "text": {n: {"visible": True, "bbox": b} for n, b in (texts or {}).items()},
            "pins": [{"number": str(i + 1), "x": x, "y": y} for i, (x, y) in enumerate(pins)]}


def wire(*points):
    return {"vertices": [{"x": x, "y": y} for x, y in points]}


def sheet(components=(), wires=(), text_labels=(), power_ports=(), graphics=(TITLE_FRAME,)):
    return {"sheet_info": SHEET_INFO, "components": list(components), "wires": list(wires),
            "text_labels": list(text_labels), "net_labels": [], "power_ports": list(power_ports),
            "ports": [], "junctions": [], "drawing_graphics": list(graphics)}


def types(result, severity=None):
    return sorted(i["type"] for i in result["issues"] if severity is None or i["severity"] == severity)


class TestLayout(unittest.TestCase):

    def test_clean_sheet(self):
        s = sheet(components=[part("R1", [1000, 1990, 1220, 2010], {"Designator": [1000, 2050, 1100, 2150]},
                                   pins=[(900, 2000), (1300, 2000)]),
                              part("R2", [2000, 1990, 2220, 2010], {"Designator": [2000, 2050, 2100, 2150]},
                                   pins=[(1900, 2000), (2300, 2000)])],
                  wires=[wire((1300, 2000), (1900, 2000))])
        self.assertEqual(analyze_layout(s)["issues"], [])

    def test_overlapping_bodies(self):
        r = analyze_layout(sheet(components=[part("U1", [1000, 1000, 2000, 2000]), part("U2", [1500, 1500, 2500, 2500])]))
        self.assertEqual(types(r, "error"), ["body_overlap"])

    def test_touching_bodies_is_only_a_warning(self):
        r = analyze_layout(sheet(components=[part("TP1", [1000, 1000, 1166, 1112]), part("TP2", [1100, 1100, 1266, 1212])]))
        self.assertEqual(types(r, "warning"), ["body_overlap"])
        self.assertEqual(types(r, "error"), [])

    def test_wire_across_body(self):
        r = analyze_layout(sheet(components=[part("U1", [1000, 1000, 2000, 2000])],
                                 wires=[wire((500, 1500), (2500, 1500))]))
        self.assertEqual(types(r, "error"), ["wire_crosses_body"])

    def test_wire_ending_at_body_edge_is_fine(self):
        r = analyze_layout(sheet(components=[part("U1", [1000, 1000, 2000, 2000])],
                                 wires=[wire((500, 1500), (1000, 1500))]))
        self.assertEqual(r["issues"], [])

    def test_text_collisions(self):
        s = sheet(components=[part("R1", [1000, 1000, 1220, 1020], {"Designator": [1000, 1100, 1200, 1200],
                                                                     "Comment": [1100, 1150, 1300, 1250]}),
                              part("R2", [1250, 1200, 1270, 1400])],
                  wires=[wire((900, 1175), (1050, 1175))])
        r = analyze_layout(s)
        self.assertIn("text_overlap", types(r))       # R1 Designator vs R1 Comment
        self.assertIn("text_over_body", types(r))     # R1 Comment over R2's body
        self.assertIn("text_over_wire", types(r))     # wire through R1 Designator

    def test_own_designator_inside_body_is_fine(self):
        s = sheet(components=[part("U1", [1000, 1000, 2000, 2000], {"Designator": [1400, 1500, 1500, 1600]})])
        self.assertEqual(analyze_layout(s)["issues"], [])

    def test_shared_label_edges_are_not_overlaps(self):
        s = sheet(components=[part("R1", [1000, 1000, 1020, 1200], {"Designator": [1100, 1100, 1250, 1200],
                                                                     "Comment": [1100, 1000, 1300, 1100]})])
        self.assertEqual(analyze_layout(s)["issues"], [])

    def test_wires_drawn_on_top_of_each_other(self):
        r = analyze_layout(sheet(wires=[wire((1000, 1000), (2000, 1000)), wire((1500, 1000), (2500, 1000))]))
        self.assertEqual(types(r), ["wire_overlap"])

    def test_title_block_and_off_sheet(self):
        s = sheet(components=[part("R1", [6000, 500, 6220, 520]), part("R2", [9400, 3000, 9620, 3020])])
        self.assertEqual(types(analyze_layout(s)), ["in_title_block", "off_sheet"])

    def test_title_block_ignores_nearby_logo(self):
        logo = {"object_id": 11, "bbox": [7344, 1200, 9250, 1663]}
        s = sheet(components=[part("R1", [6000, 2000, 6220, 2020])], graphics=(TITLE_FRAME, logo))
        r = analyze_layout(s)
        self.assertEqual(r["title_block"], TITLE_FRAME["bbox"])
        self.assertEqual(r["issues"], [])

    def test_title_block_text_is_not_checked(self):
        # A long "=Parameter" value spills past the frame; it is title block content.
        label = {"text": "=brd_rev", "x": 9000, "y": 350, "bbox": [9000, 350, 9700, 530]}
        self.assertEqual(analyze_layout(sheet(text_labels=[label]))["issues"], [])

    def test_off_grid_connection_points(self):
        s = sheet(components=[part("D2", [3000, 3400, 3200, 3600], pins=[(2980, 3500)])],
                  wires=[wire((2980, 3500), (2500, 3500))])
        offgrid = [i["object"] for i in analyze_layout(s)["issues"] if i["type"] == "off_grid"]
        self.assertEqual(offgrid, ["D2.1", "wire 1 vertex"])

    def test_diagonal_wire_is_info(self):
        r = analyze_layout(sheet(wires=[wire((1000, 1000), (1500, 1500))]))
        self.assertEqual(types(r, "info"), ["diagonal_wire"])


if __name__ == "__main__":
    unittest.main()
