"""
Offline tests for schematic_connectivity.analyze_connectivity (no Altium needed).

Run: python server/tests/test_schematic_connectivity.py
"""
import os
import sys
import unittest

sys.path.insert(0, os.path.abspath(os.path.join(os.path.dirname(__file__), '..')))

from schematic_connectivity import analyze_connectivity, analyze_project


def wire(*points):
    return {"vertices": [{"x": x, "y": y} for x, y in points]}


def resistor(des, x1, y1, x2, y2):
    """Two-pin part with pin connection points at (x1, y1) and (x2, y2)."""
    return {"designator": des, "pins": [
        {"number": "1", "name": "1", "x": x1, "y": y1},
        {"number": "2", "name": "2", "x": x2, "y": y2},
    ]}


def sheet(components=(), wires=(), junctions=(), net_labels=(), power_ports=(), ports=(), no_erc=()):
    return {"components": list(components), "wires": list(wires),
            "junctions": [{"x": x, "y": y} for x, y in junctions],
            "net_labels": list(net_labels), "power_ports": list(power_ports), "ports": list(ports),
            "no_erc": [{"x": x, "y": y} for x, y in no_erc]}


def types(result):
    return sorted(i["type"] for i in result["issues"])


class TestConnectivity(unittest.TestCase):

    def test_clean_series_circuit(self):
        s = sheet(components=[resistor("R1", 0, 0, 400, 0), resistor("R2", 1000, 0, 1400, 0)],
                  wires=[wire((400, 0), (1000, 0))],
                  power_ports=[{"net_name": "VCC", "x": 0, "y": 0}, {"net_name": "GND", "x": 1400, "y": 0}])
        r = analyze_connectivity(s)
        self.assertEqual(r["issues"], [])
        self.assertIn({"name": None, "pins": ["R1.2", "R2.1"]}, r["nets"])
        self.assertIn({"name": "VCC", "pins": ["R1.1"]}, r["nets"])
        self.assertEqual(r["unconnected_pins"], [])

    def test_wire_through_pin_shorts_two_pin_part(self):
        # The wire ends on R1.2 but runs across R1.1 on the way.
        s = sheet(components=[resistor("R1", 400, 0, 800, 0)], wires=[wire((0, 0), (800, 0))])
        r = analyze_connectivity(s)
        through = next(i for i in r["issues"] if i["type"] == "wire_through_pin")
        self.assertEqual((through["severity"], through["pin"], through["x"], through["y"]), ("info", "R1.1", 400, 0))
        short = next(i for i in r["issues"] if i["type"] == "component_pins_shorted")
        self.assertEqual(short["severity"], "error")

    def test_shared_net_on_multi_pin_part_is_info(self):
        ic = {"designator": "U1", "pins": [{"number": n, "name": n, "x": 0, "y": y}
                                           for n, y in (("1", 0), ("2", 100), ("3", 200))]}
        s = sheet(components=[ic], wires=[wire((0, 0), (0, 100))])
        short = next(i for i in analyze_connectivity(s)["issues"] if i["type"] == "component_pins_shorted")
        self.assertEqual(short["severity"], "info")

    def test_t_join_connects_without_junction_object(self):
        # Altium draws T-join dots itself and does not store them.
        s = sheet(components=[resistor("R1", 0, 0, 0, 1000), resistor("R2", 500, 1500, 900, 1500)],
                  wires=[wire((0, 1000), (0, 2000)), wire((0, 1500), (500, 1500))],
                  power_ports=[{"net_name": "A", "x": 0, "y": 2000}, {"net_name": "B", "x": 900, "y": 1500},
                               {"net_name": "C", "x": 0, "y": 0}])
        r = analyze_connectivity(s)
        self.assertEqual(r["issues"], [])
        self.assertIn({"name": "A", "pins": ["R1.2", "R2.1"]}, r["nets"])

    def test_port_far_end_names_wire(self):
        # Port at x=0 with width 650 connects at x=650 too.
        s = sheet(components=[resistor("R1", 1000, 0, 1400, 0)],
                  wires=[wire((650, 0), (1000, 0))],
                  ports=[{"name": "SPI_CLK", "x": 0, "y": 0, "width": 650, "x2": 650, "y2": 0}],
                  power_ports=[{"net_name": "GND", "x": 1400, "y": 0}])
        r = analyze_connectivity(s)
        self.assertNotIn("dangling_wire_end", types(r))
        self.assertIn({"name": "SPI_CLK", "pins": ["R1.1"]}, r["nets"])

    def test_multi_part_component_counts_all_parts(self):
        # A 4-pin crystal drawn as two parts: X1.2 and X1.4 both on GND is not a short.
        part_a = {"designator": "X1", "pins": [{"number": "1", "name": "1", "x": 0, "y": 0},
                                               {"number": "3", "name": "3", "x": 0, "y": 500}]}
        part_b = {"designator": "X1", "pins": [{"number": "2", "name": "2", "x": 1000, "y": 0},
                                               {"number": "4", "name": "4", "x": 1000, "y": 500}]}
        s = sheet(components=[part_a, part_b], wires=[wire((1000, 0), (1000, 500))])
        short = next(i for i in analyze_connectivity(s)["issues"] if i["type"] == "component_pins_shorted")
        self.assertEqual(short["severity"], "info")

    def test_no_erc_marks_intentional_opens(self):
        s = sheet(components=[resistor("R1", 0, 0, 400, 0)],
                  wires=[wire((400, 0), (800, 0))], no_erc=[(0, 0), (800, 0)])
        r = analyze_connectivity(s)
        self.assertNotIn("dangling_wire_end", types(r))
        self.assertEqual(r["unconnected_pins"], [])

    def test_crossing_wires_connect_only_with_junction(self):
        parts = [resistor("R1", -500, 0, -900, 0), resistor("R2", 500, 0, 900, 0),
                 resistor("R3", 0, -500, 0, -900), resistor("R4", 0, 500, 0, 900)]
        wires = [wire((-500, 0), (500, 0)), wire((0, -500), (0, 500))]
        apart = analyze_connectivity(sheet(components=parts, wires=wires))
        self.assertFalse(any("R1.1" in n["pins"] and "R3.1" in n["pins"] for n in apart["nets"]))
        joined = analyze_connectivity(sheet(components=parts, wires=wires, junctions=[(0, 0)]))
        self.assertTrue(any("R1.1" in n["pins"] and "R3.1" in n["pins"] for n in joined["nets"]))

    def test_dangling_end_and_floating_labels(self):
        s = sheet(components=[resistor("R1", 0, 0, 400, 0)],
                  wires=[wire((400, 0), (800, 0))],
                  net_labels=[{"net_name": "SDA", "x": 5000, "y": 5000}],
                  power_ports=[{"net_name": "GND", "x": 6000, "y": 6000}])
        r = analyze_connectivity(s)
        self.assertEqual(types(r), ["dangling_wire_end", "floating_net_label", "floating_power_port"])
        self.assertEqual(r["unconnected_pins"], ["R1.1"])

    def test_net_label_names_wire_and_conflict(self):
        s = sheet(components=[resistor("R1", 0, 0, 400, 0), resistor("R2", 1000, 0, 1400, 0)],
                  wires=[wire((400, 0), (1000, 0))],
                  net_labels=[{"net_name": "SDA", "x": 600, "y": 0}, {"net_name": "SCL", "x": 800, "y": 0}])
        r = analyze_connectivity(s)
        self.assertIn("net_name_conflict", types(r))

    def test_same_label_joins_separate_wires(self):
        s = sheet(components=[resistor("R1", 0, 0, 400, 0), resistor("R2", 2000, 0, 2400, 0)],
                  wires=[wire((400, 0), (600, 0)), wire((1800, 0), (2000, 0))],
                  net_labels=[{"net_name": "SDA", "x": 500, "y": 0}, {"net_name": "SDA", "x": 1900, "y": 0}])
        r = analyze_connectivity(s)
        self.assertIn({"name": "SDA", "pins": ["R1.2", "R2.1"]}, r["nets"])


class TestProject(unittest.TestCase):
    """Flat multi-sheet designs: ports and power ports join sheets, net labels do not."""

    def two_sheets(self, a_extra, b_extra):
        a = {"sheet": "A", **sheet(components=[resistor("R1", 0, 0, 400, 0)], wires=[wire((400, 0), (800, 0))],
                                   power_ports=[{"net_name": "GND", "x": 0, "y": 0}]), **a_extra}
        b = {"sheet": "B", **sheet(components=[resistor("R2", 1000, 0, 1400, 0)], wires=[wire((600, 0), (1000, 0))],
                                   power_ports=[{"net_name": "GND", "x": 1400, "y": 0}]), **b_extra}
        return analyze_project([a, b])

    def test_port_joins_sheets(self):
        r = self.two_sheets({"ports": [{"name": "SIG", "x": 800, "y": 0}]},
                            {"ports": [{"name": "SIG", "x": 600, "y": 0}]})
        self.assertIn({"name": "SIG", "pins": ["R1.2", "R2.1"], "sheets": ["A", "B"]}, r["nets"])
        self.assertIn({"name": "GND", "pins": ["R1.1", "R2.2"], "sheets": ["A", "B"]}, r["nets"])
        self.assertEqual([i for i in r["issues"] if i["severity"] != "info"], [])

    def test_net_label_does_not_join_sheets(self):
        r = self.two_sheets({"net_labels": [{"net_name": "SIG", "x": 600, "y": 0}]},
                            {"net_labels": [{"net_name": "SIG", "x": 800, "y": 0}]})
        sig = [n for n in r["nets"] if n["name"] == "SIG"]
        self.assertEqual(len(sig), 2)   # one per sheet, not merged

    def test_unmatched_port(self):
        r = self.two_sheets({"ports": [{"name": "SIG", "x": 800, "y": 0}]}, {})
        self.assertIn("port_unmatched", [i["type"] for i in r["issues"]])

    def test_designator_on_two_sheets(self):
        a = {"sheet": "A", **sheet(components=[resistor("R1", 0, 0, 400, 0)])}
        b = {"sheet": "B", **sheet(components=[resistor("R1", 0, 0, 400, 0)])}
        self.assertIn("designator_on_several_sheets", [i["type"] for i in analyze_project([a, b])["issues"]])


if __name__ == "__main__":
    unittest.main()
