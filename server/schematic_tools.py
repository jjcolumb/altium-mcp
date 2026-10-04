"""
Schematic editing tools: read back one sheet and edit an EXISTING schematic.

Kept in its own module so the fork can pull upstream changes to main.py with
minimal conflicts; main.py only calls register_schematic_tools().

The DelphiScript side (AltiumScript/schematic_edit.pas and schematic_read.pas)
is derived from altium-mcp by altium-mcp contributors (flaco-source),
https://github.com/flaco-source/altium-mcp, MIT License. See NOTICE.

None of these tools save the document. Edits land in Altium as one undo step
each; the user reviews and saves (or presses Ctrl+Z) in Altium.
"""
import json
from typing import Optional

from mcp.server.fastmcp import Context

from schematic_connectivity import analyze_connectivity
from schematic_layout import analyze_layout


def _format_number(value) -> str:
    """Plain decimal text (no exponent) for the DelphiScript point parser."""
    text = format(float(value), "f")
    if "." in text:
        text = text.rstrip("0").rstrip(".")
    return text


def _points_to_csv(points: list) -> str:
    """[[x1, y1], [x2, y2], ...] -> "x1,y1,x2,y2,..."; raises ValueError if malformed."""
    if not isinstance(points, list):
        raise ValueError("points must be a list of [x, y] pairs")
    numbers = []
    for point in points:
        if not isinstance(point, (list, tuple)) or len(point) != 2:
            raise ValueError(f"each point must be [x, y], got {point!r}")
        for coord in point:
            if isinstance(coord, bool) or not isinstance(coord, (int, float)):
                raise ValueError(f"coordinates must be numbers, got {coord!r}")
            numbers.append(_format_number(coord))
    return ",".join(numbers)


def register_schematic_tools(mcp, altium_bridge, logger):
    """Register the schematic read/edit tools on the server's FastMCP instance."""

    async def _schematic_edit(action: str, params: dict) -> str:
        logger.info(f"Schematic edit '{action}': {params}")
        response = await altium_bridge.execute_command("schematic_edit", {"action": action, **params})

        if not response.get("success", False):
            error_msg = response.get("error", "Unknown error")
            logger.error(f"Error in schematic edit '{action}': {error_msg}")
            return json.dumps({"success": False, "error": f"Schematic edit '{action}' failed: {error_msg}"})

        result = response.get("result", {})
        logger.info(f"Schematic edit '{action}' applied (not saved)")
        return json.dumps({"success": True, "result": result}, indent=2)

    @mcp.tool()
    async def get_schematic_objects(ctx: Context, schematic_path: str) -> str:
        """
        Read back everything on ONE schematic sheet, for checking schematic edits.

        Returns components (designator, lib_reference, position, rotation, mirrored,
        parameters, and every pin with its connection point - the end a wire must
        touch), wires and buses (all vertices), bus entries, net labels, power ports
        (net name and style), junctions, ports, text labels and sheet settings.
        All coordinates are absolute sheet coordinates in mils.

        Reads the sheet as it is in Altium, including unsaved edits. Opens the sheet
        if it is not already open.

        Args:
            schematic_path (str): Full path to the .SchDoc file

        Returns:
            str: JSON object with the sheet contents
        """
        logger.info(f"Getting schematic objects for {schematic_path}")

        response = await altium_bridge.execute_command(
            "get_schematic_objects",
            {"schematic_path": schematic_path}
        )

        if not response.get("success", False):
            error_msg = response.get("error", "Unknown error")
            logger.error(f"Error getting schematic objects: {error_msg}")
            return json.dumps({"success": False, "error": f"Failed to get schematic objects: {error_msg}"})

        return json.dumps(response.get("result", {}), indent=2)

    @mcp.tool()
    async def sch_create_sheet(ctx: Context, schematic_path: str, copy_format_from: str = "",
                               title_block_region: Optional[list] = None) -> str:
        """
        Create a NEW blank schematic sheet file, optionally formatted like an existing sheet.

        This is the only schematic tool that writes a file: it saves the new, empty (or
        formatted) sheet once, and refuses if the file already exists. The sheet is opened
        in Altium as a free document; it is not added to any project. Later sch_* edits
        on it are not saved, as usual.

        With copy_format_from it copies that sheet's size, grid and border settings, its
        sheet template file (if it uses one), its sheet parameters that have values
        (Title, Revision, ...), and every drawing object inside its title block - lines,
        rectangles, images, text frames and labels, including "=Parameter" special
        strings, which stay live. The title block is found automatically as the drawing
        graphics in the bottom-right quarter of the sheet, or given explicitly.

        Args:
            schematic_path (str): Full path for the new .SchDoc (must not exist yet)
            copy_format_from (str): Optional full path of a .SchDoc to copy the format from
            title_block_region (list): Optional [x1, y1, x2, y2] in mils on the format sheet;
                everything fully inside is copied. Default: auto-detect.

        Returns:
            str: JSON object describing what was created and copied
        """
        params = {"schematic_path": schematic_path, "copy_format_from": copy_format_from}
        if title_block_region is not None:
            if not isinstance(title_block_region, list) or len(title_block_region) != 4:
                return json.dumps({"success": False, "error": "title_block_region must be [x1, y1, x2, y2]"})
            try:
                params["title_block_region"] = _points_to_csv([title_block_region[:2], title_block_region[2:]])
            except ValueError as e:
                return json.dumps({"success": False, "error": str(e)})
        return await _schematic_edit("create_sheet", params)

    @mcp.tool()
    async def sch_move_component(ctx: Context, schematic_path: str, cmp_designator: str,
                                 x: Optional[float] = None, y: Optional[float] = None,
                                 rotation: Optional[float] = None) -> str:
        """
        Move and/or rotate a component on an existing schematic sheet (absolute values).

        The designator and parameter text move with the part. Rotation is absolute and
        snapped to 0, 90, 180 or 270 degrees. Omitted values are left unchanged. Returns
        the new pin connection points so wires can be routed to them.

        This does NOT save the schematic. After the edit, call get_schematic_objects on the
        same sheet and confirm the change before relying on it. If the edit fails, stop and
        report the error to the user instead of retrying with guessed values.

        Args:
            schematic_path (str): Full path to the .SchDoc file
            cmp_designator (str): Designator of the component (e.g. "R1")
            x (float): New absolute X of the component origin in mils (optional)
            y (float): New absolute Y of the component origin in mils (optional)
            rotation (float): New absolute rotation in degrees (optional)

        Returns:
            str: JSON object with the result of the edit
        """
        params = {"schematic_path": schematic_path, "designator": cmp_designator}
        if x is not None:
            params["x"] = x
        if y is not None:
            params["y"] = y
        if rotation is not None:
            params["rotation"] = rotation
        return await _schematic_edit("move_component", params)

    @mcp.tool()
    async def sch_set_component_parameters(ctx: Context, schematic_path: str, cmp_designator: str,
                                           parameters: dict) -> str:
        """
        Set parameter values on a component on an existing schematic sheet.

        Existing parameters (matched by name, case-insensitive, e.g. "Comment", "Value")
        are updated in place. Parameters that do not exist are created as hidden string
        parameters. Values may contain any text, including commas.

        This does NOT save the schematic. After the edit, call get_schematic_objects on the
        same sheet and confirm the change before relying on it. If the edit fails, stop and
        report the error to the user instead of retrying with guessed values.

        Args:
            schematic_path (str): Full path to the .SchDoc file
            cmp_designator (str): Designator of the component (e.g. "R1")
            parameters (dict): Parameter name -> new value, e.g. {"Value": "10k", "Tolerance": "1%"}

        Returns:
            str: JSON object listing the updated and newly created parameters
        """
        if not isinstance(parameters, dict) or not parameters:
            return json.dumps({"success": False, "error": "parameters must be a non-empty object of name -> value"})
        return await _schematic_edit("set_component_parameters", {
            "schematic_path": schematic_path,
            "designator": cmp_designator,
            "parameter_names": [str(name) for name in parameters.keys()],
            "parameter_values": [str(value) for value in parameters.values()],
        })

    @mcp.tool()
    async def sch_set_component_text(ctx: Context, schematic_path: str, cmp_designator: str,
                                     texts: list) -> str:
        """
        Position, rotate, justify, show or hide a component's designator and parameter texts.

        Use it to tidy labels after placing or moving parts so they do not overlap wires or
        other parts. get_schematic_objects returns each component's current "text" placement.
        Positions are absolute sheet coordinates in mils; moved texts stop auto-positioning.

        This does NOT save the schematic. After the edit, call get_schematic_objects on the
        same sheet and confirm the change before relying on it. If the edit fails, stop and
        report the error to the user instead of retrying with guessed values.

        Args:
            schematic_path (str): Full path to the .SchDoc file
            cmp_designator (str): Designator of the component (e.g. "R1")
            texts (list): One object per text, e.g.
                [{"name": "Designator", "x": 4300, "y": 2600},
                 {"name": "Comment", "x": 4300, "y": 2500, "visible": true, "justification": "bottom_left"},
                 {"name": "Value", "visible": false}]
                "name" is "Designator" or a parameter name (entries from get_schematic_objects
                "text" can be passed as-is; bbox is ignored). Optional keys: x, y, visible,
                rotation (0/90/180/270), justification (bottom_left, bottom_center,
                bottom_right, center_left, center, center_right, top_left, top_center,
                top_right). Omitted keys are left unchanged.

        Returns:
            str: JSON object with the resulting placement of each text
        """
        if not isinstance(texts, list) or not texts:
            return json.dumps({"success": False, "error": "texts must be a non-empty list"})
        arrays = {k: [] for k in ("text_names", "text_x", "text_y", "text_visible",
                                  "text_rotation", "text_justification")}
        for item in texts:
            if not isinstance(item, dict) or not str(item.get("name", "")).strip():
                return json.dumps({"success": False, "error": f"each text needs a name, got {item!r}"})
            # "bbox" is read-only output of get_schematic_objects; accept it so read-back
            # placements can be passed straight in.
            unknown = set(item) - {"name", "x", "y", "visible", "rotation", "justification", "bbox"}
            if unknown:
                return json.dumps({"success": False, "error": f"unknown keys {sorted(unknown)} in {item!r}"})
            try:
                arrays["text_x"].append(_format_number(item["x"]) if item.get("x") is not None else "")
                arrays["text_y"].append(_format_number(item["y"]) if item.get("y") is not None else "")
                arrays["text_rotation"].append(_format_number(item["rotation"]) if item.get("rotation") is not None else "")
            except (TypeError, ValueError):
                return json.dumps({"success": False, "error": f"x, y and rotation must be numbers in {item!r}"})
            arrays["text_names"].append(str(item["name"]))
            visible = item.get("visible")
            arrays["text_visible"].append("" if visible is None else ("true" if visible else "false"))
            arrays["text_justification"].append(str(item.get("justification") or ""))
        return await _schematic_edit("set_component_text", {
            "schematic_path": schematic_path,
            "designator": cmp_designator,
            **arrays,
        })

    @mcp.tool()
    async def sch_place_component(ctx: Context, schematic_path: str, library_path: str, lib_reference: str,
                                  designator: str, x: float, y: float, rotation: float = 0) -> str:
        """
        Place a symbol from a schematic library (.SchLib) onto an existing schematic sheet.

        Use search_library_symbol to find the lib_reference first. Fails if the designator
        already exists on the sheet. Returns the placed part's pin connection points so
        wires can be routed to them.

        This does NOT save the schematic. After the edit, call get_schematic_objects on the
        same sheet and confirm the change before relying on it. If the edit fails, stop and
        report the error to the user instead of retrying with guessed values.

        Args:
            schematic_path (str): Full path to the .SchDoc file
            library_path (str): Full path to the .SchLib containing the symbol
            lib_reference (str): Symbol name in the library (e.g. "RES-DISCRETE")
            designator (str): Designator for the new part (e.g. "R12")
            x (float): Absolute X of the component origin in mils
            y (float): Absolute Y of the component origin in mils
            rotation (float): Rotation in degrees (0, 90, 180, 270)

        Returns:
            str: JSON object with the placed component and its pins
        """
        return await _schematic_edit("place_component", {
            "schematic_path": schematic_path,
            "library_path": library_path,
            "lib_reference": lib_reference,
            "designator": designator,
            "x": x,
            "y": y,
            "rotation": rotation,
        })

    @mcp.tool()
    async def sch_add_wire(ctx: Context, schematic_path: str, points: list) -> str:
        """
        Draw one wire through a list of points on an existing schematic sheet.

        A wire connects to a pin only where its end touches the pin's connection point
        (from get_schematic_objects or the pins returned by sch_place_component). Keep
        segments horizontal or vertical. Junction dots are not added automatically.

        This does NOT save the schematic. After the edit, call get_schematic_objects on the
        same sheet and confirm the change before relying on it. If the edit fails, stop and
        report the error to the user instead of retrying with guessed values.

        Args:
            schematic_path (str): Full path to the .SchDoc file
            points (list): Vertices in mils, at least two, e.g. [[1000, 2000], [1500, 2000], [1500, 2500]]

        Returns:
            str: JSON object with the vertices of the new wire
        """
        try:
            csv = _points_to_csv(points)
        except ValueError as e:
            return json.dumps({"success": False, "error": str(e)})
        return await _schematic_edit("add_wire", {"schematic_path": schematic_path, "points": csv})

    @mcp.tool()
    async def sch_add_bus(ctx: Context, schematic_path: str, points: list) -> str:
        """
        Draw one bus through a list of points on an existing schematic sheet.

        This does NOT save the schematic. After the edit, call get_schematic_objects on the
        same sheet and confirm the change before relying on it. If the edit fails, stop and
        report the error to the user instead of retrying with guessed values.

        Args:
            schematic_path (str): Full path to the .SchDoc file
            points (list): Vertices in mils, at least two, e.g. [[1000, 2000], [1000, 3000]]

        Returns:
            str: JSON object with the vertices of the new bus
        """
        try:
            csv = _points_to_csv(points)
        except ValueError as e:
            return json.dumps({"success": False, "error": str(e)})
        return await _schematic_edit("add_bus", {"schematic_path": schematic_path, "points": csv})

    @mcp.tool()
    async def sch_add_bus_entry(ctx: Context, schematic_path: str, x1: float, y1: float,
                                x2: float, y2: float) -> str:
        """
        Add a bus entry (the short diagonal between a bus and a wire) on an existing sheet.

        Usually (x1, y1) is on the bus and (x2, y2) is offset 100 mils diagonally, where
        the wire starts.

        This does NOT save the schematic. After the edit, call get_schematic_objects on the
        same sheet and confirm the change before relying on it. If the edit fails, stop and
        report the error to the user instead of retrying with guessed values.

        Args:
            schematic_path (str): Full path to the .SchDoc file
            x1 (float): Start X in mils
            y1 (float): Start Y in mils
            x2 (float): End X in mils
            y2 (float): End Y in mils

        Returns:
            str: JSON object with the bus entry end points
        """
        csv = _points_to_csv([[x1, y1], [x2, y2]])
        return await _schematic_edit("add_bus_entry", {"schematic_path": schematic_path, "points": csv})

    @mcp.tool()
    async def sch_add_junction(ctx: Context, schematic_path: str, x: float, y: float) -> str:
        """
        Add a junction dot on an existing schematic sheet.

        Wires that cross are only connected where a junction sits on the crossing, so this
        is how to join two crossing wires. T-joins (a wire END on another wire) connect
        without one; Altium draws that dot by itself.

        This does NOT save the schematic. After the edit, call get_schematic_objects on the
        same sheet and confirm the change before relying on it. If the edit fails, stop and
        report the error to the user instead of retrying with guessed values.

        Args:
            schematic_path (str): Full path to the .SchDoc file
            x (float): X in mils (on the wires being joined)
            y (float): Y in mils (on the wires being joined)

        Returns:
            str: JSON object with the new junction
        """
        return await _schematic_edit("add_junction", {"schematic_path": schematic_path, "x": x, "y": y})

    @mcp.tool()
    async def sch_add_port(ctx: Context, schematic_path: str, name: str, x: float, y: float,
                           width: float = 600, style: str = "right", io_type: str = "unspecified") -> str:
        """
        Add a sheet port (connects a net to other sheets) on an existing schematic sheet.

        A port connects at BOTH ends: at (x, y) and at the end `width` away - (x + width, y)
        for horizontal styles, (x, y + width) for "top"/"bottom"/"top_bottom". Wire to
        either end.

        This does NOT save the schematic. After the edit, call get_schematic_objects on the
        same sheet and confirm the change before relying on it. If the edit fails, stop and
        report the error to the user instead of retrying with guessed values.

        Args:
            schematic_path (str): Full path to the .SchDoc file
            name (str): Port / net name (e.g. "MOT_IN1")
            x (float): X of one end in mils
            y (float): Y of one end in mils
            width (float): Length of the port in mils (fixed; not auto-sized to the name)
            style (str): Arrow shape: "none", "left", "right", "left_right", "top", "bottom", "top_bottom"
            io_type (str): "unspecified", "output", "input" or "bidirectional"

        Returns:
            str: JSON object with the new port
        """
        return await _schematic_edit("add_port", {
            "schematic_path": schematic_path,
            "name": name,
            "x": x,
            "y": y,
            "width": width,
            "style": style,
            "io_type": io_type,
        })

    @mcp.tool()
    async def check_schematic_connectivity(ctx: Context, schematic_path: str) -> str:
        """
        Check the wiring of ONE schematic sheet and list its nets. Read-only.

        Run this after a batch of schematic edits. Reports:
        - component_pins_shorted: error when both pins of a two-pin part are on one net;
          info for other parts (normal for e.g. multiple GND pins)
        - net_name_conflict, dangling_wire_end, floating_net_label, floating_power_port
          (warnings)
        - wire_through_pin (info): a wire runs through a pin's connection point and
          continues, which connects the pin; fine if intended, a short if not
        Also returns every net (name and pins, e.g. "R1.2") and the unconnected pins.
        Net names come from net labels, power ports, ports (either end) and off-sheet
        connectors. Crossing wires connect only at a junction; No ERC markers mark
        intentional opens. Buses and bus entries are not traced. Includes unsaved edits.

        Args:
            schematic_path (str): Full path to the .SchDoc file

        Returns:
            str: JSON object with summary, issues, nets and unconnected_pins
        """
        logger.info(f"Checking schematic connectivity for {schematic_path}")

        response = await altium_bridge.execute_command(
            "get_schematic_objects",
            {"schematic_path": schematic_path}
        )

        if not response.get("success", False):
            error_msg = response.get("error", "Unknown error")
            logger.error(f"Error reading schematic for connectivity check: {error_msg}")
            return json.dumps({"success": False, "error": f"Failed to read schematic: {error_msg}"})

        return json.dumps(analyze_connectivity(response.get("result", {})), indent=2)

    @mcp.tool()
    async def check_schematic_layout(ctx: Context, schematic_path: str) -> str:
        """
        Check the readability of ONE schematic sheet's layout. Read-only.

        Run this after placing or moving parts and drawing wires, alongside
        check_schematic_connectivity (which checks the wiring, not the drawing). Reports:
        - body_overlap: error when two parts' bodies collide; warning when they only touch
        - wire_crosses_body (error): a wire runs across a part instead of ending at a pin
        - text_overlap, text_over_wire, text_over_body (warnings): a designator, parameter,
          note, net label, power port or port collides with other text, a wire, or another
          part (a part's own designator inside its body is fine)
        - text_over_pin (warning): a designator, parameter or note runs across a pin line
        - wire_overlap (warning): two wires drawn on top of each other
        - off_sheet, in_title_block (warnings)
        - off_grid (warning): a pin, wire vertex, port or label off the snap grid
        - diagonal_wire (info)
        Each issue has x, y in mils. Title block content is not checked. Includes unsaved edits.

        Args:
            schematic_path (str): Full path to the .SchDoc file

        Returns:
            str: JSON object with summary, title_block and issues
        """
        logger.info(f"Checking schematic layout for {schematic_path}")

        response = await altium_bridge.execute_command(
            "get_schematic_objects",
            {"schematic_path": schematic_path}
        )

        if not response.get("success", False):
            error_msg = response.get("error", "Unknown error")
            logger.error(f"Error reading schematic for layout check: {error_msg}")
            return json.dumps({"success": False, "error": f"Failed to read schematic: {error_msg}"})

        return json.dumps(analyze_layout(response.get("result", {})), indent=2)

    @mcp.tool()
    async def sch_add_net_label(ctx: Context, schematic_path: str, net_name: str, x: float, y: float,
                                rotation: float = 0) -> str:
        """
        Add a net label on an existing schematic sheet.

        The label names the net only if its location lies exactly on a wire.

        This does NOT save the schematic. After the edit, call get_schematic_objects on the
        same sheet and confirm the change before relying on it. If the edit fails, stop and
        report the error to the user instead of retrying with guessed values.

        Args:
            schematic_path (str): Full path to the .SchDoc file
            net_name (str): Net name (e.g. "SDA")
            x (float): X in mils (on a wire)
            y (float): Y in mils (on a wire)
            rotation (float): Rotation in degrees (0, 90, 180, 270)

        Returns:
            str: JSON object with the new net label
        """
        return await _schematic_edit("add_net_label", {
            "schematic_path": schematic_path,
            "net_name": net_name,
            "x": x,
            "y": y,
            "rotation": rotation,
        })

    @mcp.tool()
    async def sch_add_power_port(ctx: Context, schematic_path: str, net_name: str, x: float, y: float,
                                 style: str = "", rotation: float = 0, show_net_name: bool = True) -> str:
        """
        Add a power port (VCC, GND, 3V3, ...) on an existing schematic sheet.

        The port connects at its location, so place it on a wire end or pin connection
        point. Rotation sets the direction the symbol points away from that point:
        90 = up (typical for supplies), 270 = down (typical for ground), 0 = right,
        180 = left.

        This does NOT save the schematic. After the edit, call get_schematic_objects on the
        same sheet and confirm the change before relying on it. If the edit fails, stop and
        report the error to the user instead of retrying with guessed values.

        Args:
            schematic_path (str): Full path to the .SchDoc file
            net_name (str): Net name (e.g. "GND", "3V3")
            x (float): X in mils
            y (float): Y in mils
            style (str): One of "bar", "arrow", "circle", "wave", "gnd_power", "gnd_signal",
                "gnd_earth". Empty picks "gnd_power" for nets containing GND, otherwise "bar".
            rotation (float): Direction in degrees: 90 up, 270 down, 0 right, 180 left
            show_net_name (bool): Show the net name next to the symbol

        Returns:
            str: JSON object with the new power port
        """
        return await _schematic_edit("add_power_port", {
            "schematic_path": schematic_path,
            "net_name": net_name,
            "x": x,
            "y": y,
            "style": style,
            "rotation": rotation,
            "show_net_name": show_net_name,
        })

    @mcp.tool()
    async def sch_add_text(ctx: Context, schematic_path: str, text: str, x: float, y: float,
                           rotation: float = 0, font_name: str = "", font_size: float = 0,
                           bold: Optional[bool] = None, italic: Optional[bool] = None,
                           underline: Optional[bool] = None, color: str = "",
                           justification: str = "") -> str:
        """
        Add a free text label (a note, not a net label) on an existing schematic sheet.

        Formatting is optional; anything left out uses Altium's default for new text.
        get_schematic_objects reports the font, color and justification of existing
        notes, so a note can be made to match them.

        This does NOT save the schematic. After the edit, call get_schematic_objects on the
        same sheet and confirm the change before relying on it. If the edit fails, stop and
        report the error to the user instead of retrying with guessed values.

        Args:
            schematic_path (str): Full path to the .SchDoc file
            text (str): Text to show
            x (float): X in mils
            y (float): Y in mils
            rotation (float): Rotation in degrees (0, 90, 180, 270)
            font_name (str): Font family, e.g. "Arial" (optional)
            font_size (float): Font size in points (optional)
            bold (bool): Bold (optional)
            italic (bool): Italic (optional)
            underline (bool): Underline (optional)
            color (str): Text color as "#RRGGBB" (optional)
            justification (str): bottom_left, bottom_center, bottom_right, center_left, center,
                center_right, top_left, top_center or top_right (optional)

        Returns:
            str: JSON object with the new text label and its formatting
        """
        params = {"schematic_path": schematic_path, "text": text, "x": x, "y": y, "rotation": rotation}
        if font_name:
            params["font_name"] = font_name
        if font_size:
            params["font_size"] = font_size
        for key, value in (("bold", bold), ("italic", italic), ("underline", underline)):
            if value is not None:
                params[key] = value
        if color:
            params["color"] = color
        if justification:
            params["justification"] = justification
        return await _schematic_edit("add_text", params)
