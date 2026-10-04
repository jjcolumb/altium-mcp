{..............................................................................}
{ schematic_read.pas                                                           }
{                                                                              }
{ Shared request helpers for schematic editing, plus the get_schematic_objects }
{ command: a full read-back of ONE schematic sheet (components with pin       }
{ connection points, wires, buses, bus entries, net labels, power ports,       }
{ junctions, ports, text labels, off-sheet connectors, No ERC markers and      }
{ sheet settings).                                                             }
{                                                                              }
{ Portions derived from altium-mcp by altium-mcp contributors (flaco-source),  }
{ https://github.com/flaco-source/altium-mcp                                   }
{                                                                              }
{ MIT License                                                                  }
{ Copyright (c) 2026 altium-mcp contributors                                   }
{                                                                              }
{ Permission is hereby granted, free of charge, to any person obtaining a copy }
{ of this software and associated documentation files (the "Software"), to    }
{ deal in the Software without restriction, including without limitation the  }
{ rights to use, copy, modify, merge, publish, distribute, sublicense, and/or  }
{ sell copies of the Software, and to permit persons to whom the Software is   }
{ furnished to do so, subject to the following conditions:                     }
{                                                                              }
{ The above copyright notice and this permission notice shall be included in  }
{ all copies or substantial portions of the Software.                          }
{                                                                              }
{ THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR   }
{ IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,     }
{ FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE  }
{ AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER       }
{ LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING      }
{ FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS }
{ IN THE SOFTWARE.                                                             }
{..............................................................................}

{..............................................................................}
{ Request parsing                                                              }
{                                                                              }
{ TrimJSON strips every quote and comma, which corrupts values such as         }
{ "10k, 1%" or a comma-separated point list. These helpers decode one JSON     }
{ value properly. They rely on the server writing request.json with indent=2,  }
{ i.e. one key per line and one array element per line.                        }
{..............................................................................}

function SchMcpIsHexDigit(C: String): Boolean;
begin
    Result := Pos(UpperCase(C), '0123456789ABCDEF') > 0;
end;

// Decode the JSON value that starts at position Start of Line. Strings are
// unescaped; bare tokens (numbers, true, false) lose their trailing comma;
// null becomes ''.
function SchMcpDecodeJSONValue(Line: String; Start: Integer): String;
var
    i, LenLine: Integer;
    C, Hex: String;
begin
    Result := '';
    LenLine := Length(Line);
    i := Start;
    while (i <= LenLine) and (Line[i] <= ' ') do
        i := i + 1;
    if i > LenLine then
        Exit;

    if Line[i] = '"' then
    begin
        i := i + 1;
        while i <= LenLine do
        begin
            C := Line[i];
            if C = '\' then
            begin
                i := i + 1;
                if i > LenLine then
                    Break;
                C := Line[i];
                if C = 'n' then
                    Result := Result + #10
                else if C = 'r' then
                    Result := Result + #13
                else if C = 't' then
                    Result := Result + #9
                else if C = 'u' then
                begin
                    Hex := Copy(Line, i + 1, 4);
                    if (Length(Hex) = 4) and SchMcpIsHexDigit(Hex[1]) and SchMcpIsHexDigit(Hex[2]) and
                       SchMcpIsHexDigit(Hex[3]) and SchMcpIsHexDigit(Hex[4]) then
                    begin
                        Result := Result + Chr(StrToInt('$' + Hex));
                        i := i + 4;
                    end;
                end
                else
                    Result := Result + C;
                i := i + 1;
            end
            else if C = '"' then
                Break
            else
            begin
                Result := Result + C;
                i := i + 1;
            end;
        end;
        Exit;
    end;

    Result := Trim(Copy(Line, i, LenLine - i + 1));
    while (Length(Result) > 0) and (Result[Length(Result)] = ',') do
        Result := Trim(Copy(Result, 1, Length(Result) - 1));
    if LowerCase(Result) = 'null' then
        Result := '';
end;

// Index of the request line holding "Key": as a top-level key, or -1. Matches
// the whole quoted key so "x" never matches "x_mils".
function SchMcpFindKeyLine(RequestData: TStringList; Key: String): Integer;
var
    i: Integer;
begin
    Result := -1;
    for i := 0 to RequestData.Count - 1 do
        if Pos('"' + Key + '":', Trim(RequestData[i])) = 1 then
        begin
            Result := i;
            Exit;
        end;
end;

function SchMcpHasKey(RequestData: TStringList; Key: String): Boolean;
var
    Idx: Integer;
begin
    Result := False;
    Idx := SchMcpFindKeyLine(RequestData, Key);
    if Idx < 0 then
        Exit;
    Result := SchMcpDecodeJSONValue(RequestData[Idx], Pos(':', RequestData[Idx]) + 1) <> '';
end;

function SchMcpGetString(RequestData: TStringList; Key: String): String;
var
    Idx: Integer;
begin
    Result := '';
    Idx := SchMcpFindKeyLine(RequestData, Key);
    if Idx >= 0 then
        Result := SchMcpDecodeJSONValue(RequestData[Idx], Pos(':', RequestData[Idx]) + 1);
end;

// DelphiScript try/except does not catch conversion errors reliably, so
// validate before StrToFloat ever sees the text.
function SchMcpIsNumber(S: String): Boolean;
var
    i: Integer;
    HasDigit: Boolean;
begin
    Result := False;
    S := Trim(S);
    if S = '' then
        Exit;
    HasDigit := False;
    for i := 1 to Length(S) do
    begin
        if Pos(S[i], '0123456789') > 0 then
            HasDigit := True
        else if Pos(S[i], '-+.eE') = 0 then
            Exit;
    end;
    Result := HasDigit;
end;

// Found is False when the key is missing or empty; Valid is False when it is
// present but not a number.
function SchMcpGetFloat(RequestData: TStringList; Key: String; var Found: Boolean; var Valid: Boolean): Double;
var
    S: String;
begin
    Result := 0;
    Valid := True;
    S := SchMcpGetString(RequestData, Key);
    Found := S <> '';
    if not Found then
        Exit;
    if not SchMcpIsNumber(S) then
    begin
        Valid := False;
        Exit;
    end;
    Result := SafeStrToFloat(S);
end;

function SchMcpGetBool(RequestData: TStringList; Key: String; DefaultVal: Boolean): Boolean;
var
    S: String;
begin
    S := LowerCase(SchMcpGetString(RequestData, Key));
    if (S = 'true') or (S = '1') then
        Result := True
    else if (S = 'false') or (S = '0') then
        Result := False
    else
        Result := DefaultVal;
end;

// One element per line until the closing bracket. Elements may contain commas
// and brackets because each one is decoded as a full JSON value.
procedure SchMcpGetStringArray(RequestData: TStringList; Key: String; List: TStringList);
var
    Idx, i: Integer;
    Line: String;
begin
    Idx := SchMcpFindKeyLine(RequestData, Key);
    if Idx < 0 then
        Exit;
    if Pos('[]', RequestData[Idx]) > 0 then
        Exit;
    i := Idx + 1;
    while i < RequestData.Count do
    begin
        Line := Trim(RequestData[i]);
        if (Length(Line) > 0) and (Line[1] = ']') then
            Break;
        if Line <> '' then
            List.Add(SchMcpDecodeJSONValue(Line, 1));
        i := i + 1;
    end;
end;

{..............................................................................}
{ Sheet resolution                                                             }
{..............................................................................}

// Collapse slash direction and doubled separators so request paths compare
// equal to Altium's DM_FullPath (derived from flaco-source McpNormalizeWindowsPath).
function SchMcpNormalizePath(S: String): String;
var
    T, Prev: String;
    IsUnc: Boolean;
begin
    T := Trim(StringReplace(S, '/', '\', REPLACEALL));
    IsUnc := (Length(T) >= 2) and (T[1] = '\') and (T[2] = '\');
    if IsUnc then
        T := Copy(T, 3, Length(T));
    repeat
        Prev := T;
        T := StringReplace(T, '\\', '\', REPLACEALL);
    until T = Prev;
    if IsUnc then
        T := '\\' + T;
    Result := T;
end;

// Open (if needed) and return the schematic sheet at SheetPath. Returns '' on
// success, otherwise an 'ERROR: ...' string. Never falls back to the focused
// document: an edit must land on exactly the sheet the caller named.
function SchMcpResolveSheet(SheetPath: String; var SchDoc: ISch_Document): String;
var
    ServerDoc: IServerDocument;
begin
    Result := '';
    SchDoc := nil;

    if SheetPath = '' then
    begin
        Result := 'ERROR: schematic_path is required';
        Exit;
    end;
    if LowerCase(ExtractFileExt(SheetPath)) <> '.schdoc' then
    begin
        Result := 'ERROR: schematic_path must be a .SchDoc file: ' + SheetPath;
        Exit;
    end;
    if not FileExists(SheetPath) then
    begin
        Result := 'ERROR: Schematic file not found: ' + SheetPath;
        Exit;
    end;

    SchDoc := SchServer.GetSchDocumentByPath(SheetPath);
    if SchDoc = nil then
    begin
        ServerDoc := Client.OpenDocument('SCH', SheetPath);
        if ServerDoc <> nil then
            Client.ShowDocument(ServerDoc);
        Sleep(300);
        SchDoc := SchServer.GetSchDocumentByPath(SheetPath);
    end;

    if SchDoc = nil then
    begin
        Result := 'ERROR: Could not open schematic: ' + SheetPath;
        Exit;
    end;
    // 32 = schematic sheet, 33 = schematic library (see BuildCircuitFromSpec).
    if SchDoc.ObjectID <> 32 then
    begin
        SchDoc := nil;
        Result := 'ERROR: Document is not a schematic sheet: ' + SheetPath;
        Exit;
    end;
end;

{..............................................................................}
{ Serialization                                                                }
{..............................................................................}

function SchMcpOrientationDeg(Orientation: Integer): Integer;
begin
    Result := (Orientation mod 4) * 90;
end;

function SchMcpPowerStyleName(Style: Integer): String;
begin
    if Style = ePowerCircle then Result := 'circle'
    else if Style = ePowerArrow then Result := 'arrow'
    else if Style = ePowerBar then Result := 'bar'
    else if Style = ePowerWave then Result := 'wave'
    else if Style = ePowerGndPower then Result := 'gnd_power'
    else if Style = ePowerGndSignal then Result := 'gnd_signal'
    else if Style = ePowerGndEarth then Result := 'gnd_earth'
    else Result := IntToStr(Style);
end;

function SchMcpPortStyleName(Style: Integer): String;
begin
    if Style = ePortNone then Result := 'none'
    else if Style = ePortLeft then Result := 'left'
    else if Style = ePortRight then Result := 'right'
    else if Style = ePortLeftRight then Result := 'left_right'
    else if Style = ePortTop then Result := 'top'
    else if Style = ePortBottom then Result := 'bottom'
    else if Style = ePortTopBottom then Result := 'top_bottom'
    else Result := IntToStr(Style);
end;

function SchMcpPortIOTypeName(IOType: Integer): String;
begin
    if IOType = ePortUnspecified then Result := 'unspecified'
    else if IOType = ePortOutput then Result := 'output'
    else if IOType = ePortInput then Result := 'input'
    else if IOType = ePortBidirectional then Result := 'bidirectional'
    else Result := IntToStr(IOType);
end;

function SchMcpPointJSON(X, Y: Integer): String;
var
    Props: TStringList;
begin
    Props := TStringList.Create;
    try
        AddJSONNumber(Props, 'x', CoordToMils(X));
        AddJSONNumber(Props, 'y', CoordToMils(Y));
        Result := BuildJSONObject(Props, 2);
    finally
        Props.Free;
    end;
end;

// Wires and buses are polylines: every vertex, in order.
function SchMcpVerticesJSON(Poly: ISch_Polyline): String;
var
    Items: TStringList;
    V: Integer;
    Pt: TLocation;
begin
    Items := TStringList.Create;
    try
        for V := 1 to Poly.VerticesCount do
        begin
            Pt := Poly.Vertex[V];
            Items.Add(SchMcpPointJSON(Pt.X, Pt.Y));
        end;
        Result := BuildJSONArray(Items, '', 1);
    finally
        Items.Free;
    end;
end;

// Pins of the visible part only, with the hot (connection) end - the point a
// wire must touch. Uses GetPinHotEnd from schematic_utils.pas.
function SchMcpPinsJSON(Comp: ISch_Component): String;
var
    Items, Props: TStringList;
    Iter: ISch_Iterator;
    Pin: ISch_Pin;
    HotX, HotY: Integer;
begin
    Items := TStringList.Create;
    try
        Iter := Comp.SchIterator_Create;
        Iter.AddFilter_ObjectSet(MkSet(ePin));
        Pin := Iter.FirstSchObject;
        while Pin <> nil do
        begin
            if (Pin.OwnerPartId = 0) or (Pin.OwnerPartId = Comp.CurrentPartID) then
            begin
                GetPinHotEnd(Pin, HotX, HotY);
                Props := TStringList.Create;
                try
                    AddJSONProperty(Props, 'number', Pin.Designator);
                    AddJSONProperty(Props, 'name', Pin.Name);
                    AddJSONNumber(Props, 'x', HotX);
                    AddJSONNumber(Props, 'y', HotY);
                    Items.Add(BuildJSONObject(Props, 2));
                finally
                    Props.Free;
                end;
            end;
            Pin := Iter.NextSchObject;
        end;
        Comp.SchIterator_Destroy(Iter);
        Result := BuildJSONArray(Items, '', 1);
    finally
        Items.Free;
    end;
end;

// TTextJustification order: bottom row, center row, top row; left to right.
function SchMcpJustificationName(Just: Integer): String;
begin
    case Just of
        0: Result := 'bottom_left';
        1: Result := 'bottom_center';
        2: Result := 'bottom_right';
        3: Result := 'center_left';
        4: Result := 'center';
        5: Result := 'center_right';
        6: Result := 'top_left';
        7: Result := 'top_center';
        8: Result := 'top_right';
    else
        Result := IntToStr(Just);
    end;
end;

// TColor is $00BBGGRR; report it as #RRGGBB.
function SchMcpColorHex(Color: Integer): String;
begin
    Result := '#' + IntToHex(Color and $FF, 2) + IntToHex((Color shr 8) and $FF, 2) +
              IntToHex((Color shr 16) and $FF, 2);
end;

// A sheet font-table entry as {name, size, bold, italic, underline}.
function SchMcpFontJSON(FontID: Integer): String;
var
    Props: TStringList;
begin
    Props := TStringList.Create;
    try
        AddJSONProperty(Props, 'name', SchServer.FontManager.FontName(FontID));
        AddJSONInteger(Props, 'size', SchServer.FontManager.Size(FontID));
        AddJSONBoolean(Props, 'bold', SchServer.FontManager.Bold(FontID));
        AddJSONBoolean(Props, 'italic', SchServer.FontManager.Italic(FontID));
        AddJSONBoolean(Props, 'underline', SchServer.FontManager.Underline(FontID));
        Result := BuildJSONObject(Props, 2);
    finally
        Props.Free;
    end;
end;

// Placement of one component text (designator or parameter).
function SchMcpTextPlacementJSON(Txt: ISch_GraphicalObject): String;
var
    Props: TStringList;
begin
    Props := TStringList.Create;
    try
        AddJSONNumber(Props, 'x', CoordToMils(Txt.Location.X));
        AddJSONNumber(Props, 'y', CoordToMils(Txt.Location.Y));
        AddJSONBoolean(Props, 'visible', not Txt.IsHidden);
        AddJSONInteger(Props, 'rotation', SchMcpOrientationDeg(Txt.Orientation));
        AddJSONProperty(Props, 'justification', SchMcpJustificationName(Txt.Justification));
        Result := BuildJSONObject(Props, 2);
    finally
        Props.Free;
    end;
end;

function SchMcpComponentJSON(Comp: ISch_Component): String;
var
    Props, ParamProps, TextProps: TStringList;
    Iter: ISch_Iterator;
    Param: ISch_Parameter;
begin
    Props := TStringList.Create;
    ParamProps := TStringList.Create;
    TextProps := TStringList.Create;
    try
        TextProps.Add('"Designator": ' + SchMcpTextPlacementJSON(Comp.Designator));
        AddJSONProperty(Props, 'designator', Comp.Designator.Text);
        AddJSONProperty(Props, 'lib_reference', Comp.LibReference);
        AddJSONNumber(Props, 'x', CoordToMils(Comp.Location.X));
        AddJSONNumber(Props, 'y', CoordToMils(Comp.Location.Y));
        AddJSONInteger(Props, 'rotation', SchMcpOrientationDeg(Comp.Orientation));
        AddJSONBoolean(Props, 'mirrored', Comp.IsMirrored);
        AddJSONInteger(Props, 'part_id', Comp.CurrentPartID);

        Iter := Comp.SchIterator_Create;
        Iter.AddFilter_ObjectSet(MkSet(eParameter));
        Param := Iter.FirstSchObject;
        while Param <> nil do
        begin
            AddJSONProperty(ParamProps, Param.Name, Param.Text);
            TextProps.Add('"' + JSONEscapeString(Param.Name) + '": ' + SchMcpTextPlacementJSON(Param));
            Param := Iter.NextSchObject;
        end;
        Comp.SchIterator_Destroy(Iter);
        Props.Add('"parameters": ' + BuildJSONObject(ParamProps, 1));
        Props.Add('"text": ' + BuildJSONObject(TextProps, 1));
        Props.Add('"pins": ' + SchMcpPinsJSON(Comp));

        Result := BuildJSONObject(Props, 1);
    finally
        TextProps.Free;
        ParamProps.Free;
        Props.Free;
    end;
end;

// Derived from flaco-source SchBuildSheetInfoObject.
function SchMcpSheetInfoJSON(SchDoc: ISch_Document): String;
var
    Props: TStringList;
begin
    Props := TStringList.Create;
    try
        AddJSONBoolean(Props, 'use_custom_sheet', SchDoc.UseCustomSheet);
        AddJSONNumber(Props, 'sheet_size_x', CoordToMils(SchDoc.GetState_SheetSizeX));
        AddJSONNumber(Props, 'sheet_size_y', CoordToMils(SchDoc.GetState_SheetSizeY));
        AddJSONNumber(Props, 'snap_grid', CoordToMils(SchDoc.GetState_SnapGridSize));
        AddJSONNumber(Props, 'visible_grid', CoordToMils(SchDoc.GetState_VisibleGridSize));
        AddJSONBoolean(Props, 'snap_grid_on', SchDoc.SnapGridOn);
        Result := BuildJSONObject(Props, 1);
    finally
        Props.Free;
    end;
end;

// Serialize one non-component primitive into the bucket for its kind.
// Derived from flaco-source SchSerializeDrawingObject, extended with
// orientation, power-port style and port I/O type.
procedure SchMcpAddPrimitive(Obj: ISch_GraphicalObject; Wires, Buses, BusEntries, NetLabels,
    PowerPorts, Junctions, Ports, Labels, OffSheet, NoErc: TStringList);
var
    Props: TStringList;
    Rect: IDispatch;
begin
    Props := TStringList.Create;
    try
        if Obj.ObjectId = eWire then
        begin
            Props.Add('"vertices": ' + SchMcpVerticesJSON(Obj));
            Wires.Add(BuildJSONObject(Props, 1));
        end
        else if Obj.ObjectId = eBus then
        begin
            Props.Add('"vertices": ' + SchMcpVerticesJSON(Obj));
            Buses.Add(BuildJSONObject(Props, 1));
        end
        else if Obj.ObjectId = eBusEntry then
        begin
            AddJSONNumber(Props, 'x1', CoordToMils(Obj.Location.X));
            AddJSONNumber(Props, 'y1', CoordToMils(Obj.Location.Y));
            AddJSONNumber(Props, 'x2', CoordToMils(Obj.Corner.X));
            AddJSONNumber(Props, 'y2', CoordToMils(Obj.Corner.Y));
            BusEntries.Add(BuildJSONObject(Props, 1));
        end
        else if Obj.ObjectId = eNetLabel then
        begin
            AddJSONProperty(Props, 'net_name', Obj.Text);
            AddJSONNumber(Props, 'x', CoordToMils(Obj.Location.X));
            AddJSONNumber(Props, 'y', CoordToMils(Obj.Location.Y));
            AddJSONInteger(Props, 'rotation', SchMcpOrientationDeg(Obj.Orientation));
            NetLabels.Add(BuildJSONObject(Props, 1));
        end
        else if Obj.ObjectId = ePowerObject then
        begin
            AddJSONProperty(Props, 'net_name', Obj.Text);
            AddJSONProperty(Props, 'style', SchMcpPowerStyleName(Obj.Style));
            AddJSONBoolean(Props, 'show_net_name', Obj.ShowNetName);
            AddJSONNumber(Props, 'x', CoordToMils(Obj.Location.X));
            AddJSONNumber(Props, 'y', CoordToMils(Obj.Location.Y));
            AddJSONInteger(Props, 'rotation', SchMcpOrientationDeg(Obj.Orientation));
            PowerPorts.Add(BuildJSONObject(Props, 1));
        end
        else if Obj.ObjectId = eJunction then
        begin
            AddJSONNumber(Props, 'x', CoordToMils(Obj.Location.X));
            AddJSONNumber(Props, 'y', CoordToMils(Obj.Location.Y));
            Junctions.Add(BuildJSONObject(Props, 1));
        end
        else if Obj.ObjectId = ePort then
        begin
            AddJSONProperty(Props, 'name', Obj.Name);
            AddJSONProperty(Props, 'io_type', SchMcpPortIOTypeName(Obj.IOType));
            AddJSONProperty(Props, 'style', SchMcpPortStyleName(Obj.Style));
            AddJSONNumber(Props, 'x', CoordToMils(Obj.Location.X));
            AddJSONNumber(Props, 'y', CoordToMils(Obj.Location.Y));
            AddJSONNumber(Props, 'width', CoordToMils(Obj.Width));
            // A port connects at BOTH ends. Its shape is long in the direction
            // it points, so the bounding box tells horizontal from vertical.
            Rect := Obj.BoundingRectangle;
            if (Rect.Top - Rect.Bottom) > (Rect.Right - Rect.Left) then
            begin
                AddJSONNumber(Props, 'x2', CoordToMils(Obj.Location.X));
                AddJSONNumber(Props, 'y2', CoordToMils(Obj.Location.Y + Obj.Width));
            end
            else
            begin
                AddJSONNumber(Props, 'x2', CoordToMils(Obj.Location.X + Obj.Width));
                AddJSONNumber(Props, 'y2', CoordToMils(Obj.Location.Y));
            end;
            Ports.Add(BuildJSONObject(Props, 1));
        end
        else if Obj.ObjectId = eLabel then
        begin
            AddJSONProperty(Props, 'text', Obj.Text);
            AddJSONNumber(Props, 'x', CoordToMils(Obj.Location.X));
            AddJSONNumber(Props, 'y', CoordToMils(Obj.Location.Y));
            AddJSONInteger(Props, 'rotation', SchMcpOrientationDeg(Obj.Orientation));
            AddJSONProperty(Props, 'justification', SchMcpJustificationName(Obj.Justification));
            AddJSONProperty(Props, 'color', SchMcpColorHex(Obj.Color));
            Props.Add('"font": ' + SchMcpFontJSON(Obj.FontID));
            Labels.Add(BuildJSONObject(Props, 1));
        end
        else if Obj.ObjectId = eCrossSheetConnector then
        begin
            AddJSONProperty(Props, 'net_name', Obj.Text);
            AddJSONNumber(Props, 'x', CoordToMils(Obj.Location.X));
            AddJSONNumber(Props, 'y', CoordToMils(Obj.Location.Y));
            OffSheet.Add(BuildJSONObject(Props, 1));
        end
        else if Obj.ObjectId = eNoERC then
        begin
            AddJSONNumber(Props, 'x', CoordToMils(Obj.Location.X));
            AddJSONNumber(Props, 'y', CoordToMils(Obj.Location.Y));
            NoErc.Add(BuildJSONObject(Props, 1));
        end;
    finally
        Props.Free;
    end;
end;

function GetSchematicObjects(RequestData: TStringList): String;
var
    SheetPath, Err: String;
    SchDoc: ISch_Document;
    Iter: ISch_Iterator;
    Obj: ISch_GraphicalObject;
    Props, Components, Wires, Buses, BusEntries, NetLabels, PowerPorts, Junctions, Ports, Labels: TStringList;
    OffSheet, NoErc: TStringList;
begin
    SheetPath := SchMcpNormalizePath(SchMcpGetString(RequestData, 'schematic_path'));
    Err := SchMcpResolveSheet(SheetPath, SchDoc);
    if Err <> '' then
    begin
        Result := Err;
        Exit;
    end;

    Props := TStringList.Create;
    Components := TStringList.Create;
    Wires := TStringList.Create;
    Buses := TStringList.Create;
    BusEntries := TStringList.Create;
    NetLabels := TStringList.Create;
    PowerPorts := TStringList.Create;
    Junctions := TStringList.Create;
    Ports := TStringList.Create;
    Labels := TStringList.Create;
    OffSheet := TStringList.Create;
    NoErc := TStringList.Create;
    try
        Iter := SchDoc.SchIterator_Create;
        Iter.SetState_IterationDepth(eIterateFirstLevel);
        Iter.AddFilter_ObjectSet(MkSet(eSchComponent, eWire, eBus, eBusEntry, eNetLabel,
            ePowerObject, eJunction, ePort, eLabel, eCrossSheetConnector, eNoERC));
        Obj := Iter.FirstSchObject;
        while Obj <> nil do
        begin
            if Obj.ObjectId = eSchComponent then
                Components.Add(SchMcpComponentJSON(Obj))
            else
                SchMcpAddPrimitive(Obj, Wires, Buses, BusEntries, NetLabels, PowerPorts, Junctions, Ports, Labels,
                    OffSheet, NoErc);
            Obj := Iter.NextSchObject;
        end;
        SchDoc.SchIterator_Destroy(Iter);

        AddJSONProperty(Props, 'sheet', SheetPath);
        AddJSONProperty(Props, 'units', 'mils');
        Props.Add('"sheet_info": ' + SchMcpSheetInfoJSON(SchDoc));
        Props.Add(BuildJSONArray(Components, 'components'));
        Props.Add(BuildJSONArray(Wires, 'wires'));
        Props.Add(BuildJSONArray(Buses, 'buses'));
        Props.Add(BuildJSONArray(BusEntries, 'bus_entries'));
        Props.Add(BuildJSONArray(NetLabels, 'net_labels'));
        Props.Add(BuildJSONArray(PowerPorts, 'power_ports'));
        Props.Add(BuildJSONArray(Junctions, 'junctions'));
        Props.Add(BuildJSONArray(Ports, 'ports'));
        Props.Add(BuildJSONArray(Labels, 'text_labels'));
        Props.Add(BuildJSONArray(OffSheet, 'off_sheet_connectors'));
        Props.Add(BuildJSONArray(NoErc, 'no_erc'));
        Result := BuildJSONObject(Props);
    finally
        NoErc.Free;
        OffSheet.Free;
        Labels.Free;
        Ports.Free;
        Junctions.Free;
        PowerPorts.Free;
        NetLabels.Free;
        BusEntries.Free;
        Buses.Free;
        Wires.Free;
        Components.Free;
        Props.Free;
    end;
end;
