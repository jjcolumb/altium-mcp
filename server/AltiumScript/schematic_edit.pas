{..............................................................................}
{ schematic_edit.pas                                                           }
{                                                                              }
{ The schematic_edit command: one edit action on an EXISTING schematic sheet.  }
{ Actions: move_component, set_component_parameters, place_component,         }
{ add_wire, add_bus, add_bus_entry, add_junction, add_net_label,              }
{ add_power_port, add_text.                                                    }
{                                                                              }
{ Every edit is wrapped in PreProcess/PostProcess (one undo step), new objects }
{ are registered with the robot manager, and modified objects are bracketed by }
{ SCHM_BeginModify/SCHM_EndModify. The document is NEVER saved here: the user }
{ reviews the change in Altium and saves it (or undoes it) themselves.         }
{                                                                              }
{ Request helpers (SchMcpGet*, SchMcpResolveSheet) live in schematic_read.pas. }
{                                                                              }
{ Derived from schematic_edit.pas in altium-mcp by altium-mcp contributors     }
{ (flaco-source), https://github.com/flaco-source/altium-mcp                   }
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

function SchEditRotationFromDeg(Deg: Double): Integer;
var
    N: Integer;
begin
    N := Round(Deg / 90.0) mod 4;
    if N < 0 then
        N := N + 4;
    if N = 1 then Result := eRotate90
    else if N = 2 then Result := eRotate180
    else if N = 3 then Result := eRotate270
    else Result := eRotate0;
end;

// Returns True and sets Style when S is a recognised style name.
function SchEditParsePowerStyle(S: String; var Style: Integer): Boolean;
begin
    Result := True;
    S := LowerCase(Trim(S));
    if S = 'circle' then Style := ePowerCircle
    else if S = 'arrow' then Style := ePowerArrow
    else if S = 'bar' then Style := ePowerBar
    else if S = 'wave' then Style := ePowerWave
    else if S = 'gnd_power' then Style := ePowerGndPower
    else if S = 'gnd_signal' then Style := ePowerGndSignal
    else if S = 'gnd_earth' then Style := ePowerGndEarth
    else Result := False;
end;

function SchEditFindComponent(SchDoc: ISch_Document; Designator: String): ISch_Component;
var
    Iter: ISch_Iterator;
    Comp: ISch_Component;
begin
    Result := nil;
    Iter := SchDoc.SchIterator_Create;
    Iter.SetState_IterationDepth(eIterateFirstLevel);
    Iter.AddFilter_ObjectSet(MkSet(eSchComponent));
    Comp := Iter.FirstSchObject;
    while Comp <> nil do
    begin
        if UpperCase(Trim(Comp.Designator.Text)) = UpperCase(Trim(Designator)) then
        begin
            Result := Comp;
            Break;
        end;
        Comp := Iter.NextSchObject;
    end;
    SchDoc.SchIterator_Destroy(Iter);
end;

// Parse "x1,y1,x2,y2,..." into Coords (as strings, mils). Returns '' or an
// 'ERROR: ...'. Every number is validated BEFORE any object is created, so a
// bad point list never leaves a half-drawn wire behind.
function SchEditParsePoints(CSV: String; MinPoints: Integer; Coords: TStringList): String;
var
    S, Item: String;
    P, i: Integer;
begin
    Result := '';
    Coords.Clear;
    S := StringReplace(Trim(CSV), ' ', '', REPLACEALL);
    while S <> '' do
    begin
        P := Pos(',', S);
        if P = 0 then
        begin
            Item := S;
            S := '';
        end
        else
        begin
            Item := Copy(S, 1, P - 1);
            S := Copy(S, P + 1, Length(S));
        end;
        Coords.Add(Item);
    end;

    if (Coords.Count mod 2) <> 0 then
    begin
        Result := 'ERROR: points must be x,y pairs (got an odd count of numbers)';
        Exit;
    end;
    if Coords.Count < MinPoints * 2 then
    begin
        Result := 'ERROR: at least ' + IntToStr(MinPoints) + ' points are required';
        Exit;
    end;
    for i := 0 to Coords.Count - 1 do
        if not SchMcpIsNumber(Coords[i]) then
        begin
            Result := 'ERROR: not a number in points: "' + Coords[i] + '"';
            Exit;
        end;
end;

function SchEditCoord(Coords: TStringList; Index: Integer): Integer;
begin
    Result := MilsToCoord(SafeStrToFloat(Coords[Index]));
end;

// Register a new top-level primitive on the sheet (same sequence as
// BuildCircuitFromSpec).
procedure SchEditRegister(SchDoc: ISch_Document; Obj: ISch_GraphicalObject);
begin
    SchDoc.RegisterSchObjectInContainer(Obj);
    SchServer.RobotManager.SendMessage(SchDoc.I_ObjectAddress, c_BroadCast,
        SCHM_PrimitiveRegistration, Obj.I_ObjectAddress);
end;

procedure SchEditBeginModify(Obj: ISch_GraphicalObject);
begin
    SchServer.RobotManager.SendMessage(Obj.I_ObjectAddress, c_BroadCast, SCHM_BeginModify, c_NoEventData);
end;

procedure SchEditEndModify(Obj: ISch_GraphicalObject);
begin
    SchServer.RobotManager.SendMessage(Obj.I_ObjectAddress, c_BroadCast, SCHM_EndModify, c_NoEventData);
end;

{..............................................................................}
{ Actions. Each returns a JSON object string or 'ERROR: ...'.                  }
{..............................................................................}

// Absolute move and/or rotation. MoveByXY (not Location) so the designator
// and parameter text travel with the part.
function SchEditMoveComponent(SchDoc: ISch_Document; RequestData: TStringList): String;
var
    Designator: String;
    Comp: ISch_Component;
    X, Y, Rot: Double;
    HasX, HasY, HasRot, ValidX, ValidY, ValidRot: Boolean;
    Props: TStringList;
begin
    Designator := SchMcpGetString(RequestData, 'designator');
    X := SchMcpGetFloat(RequestData, 'x', HasX, ValidX);
    Y := SchMcpGetFloat(RequestData, 'y', HasY, ValidY);
    Rot := SchMcpGetFloat(RequestData, 'rotation', HasRot, ValidRot);
    if Designator = '' then
    begin
        Result := 'ERROR: designator is required';
        Exit;
    end;
    if not (ValidX and ValidY and ValidRot) then
    begin
        Result := 'ERROR: x, y and rotation must be numbers';
        Exit;
    end;
    if not (HasX or HasY or HasRot) then
    begin
        Result := 'ERROR: give at least one of x, y, rotation';
        Exit;
    end;

    Comp := SchEditFindComponent(SchDoc, Designator);
    if Comp = nil then
    begin
        Result := 'ERROR: Component not found on sheet: ' + Designator;
        Exit;
    end;
    if not HasX then X := CoordToMils(Comp.Location.X);
    if not HasY then Y := CoordToMils(Comp.Location.Y);

    SchEditBeginModify(Comp);
    if HasRot then
        Comp.Orientation := SchEditRotationFromDeg(Rot);
    Comp.MoveByXY(MilsToCoord(X) - Comp.Location.X, MilsToCoord(Y) - Comp.Location.Y);
    SchEditEndModify(Comp);

    Props := TStringList.Create;
    try
        AddJSONProperty(Props, 'designator', Comp.Designator.Text);
        AddJSONNumber(Props, 'x', CoordToMils(Comp.Location.X));
        AddJSONNumber(Props, 'y', CoordToMils(Comp.Location.Y));
        AddJSONInteger(Props, 'rotation', SchMcpOrientationDeg(Comp.Orientation));
        Props.Add('"pins": ' + SchMcpPinsJSON(Comp));
        Result := BuildJSONObject(Props);
    finally
        Props.Free;
    end;
end;

// Update existing parameters by name (case-insensitive); create missing ones
// as hidden string parameters at the component origin.
function SchEditSetParameters(SchDoc: ISch_Document; RequestData: TStringList): String;
var
    Designator: String;
    Comp: ISch_Component;
    Names, Values, Updated, Created: TStringList;
    Iter: ISch_Iterator;
    Param: ISch_Parameter;
    i: Integer;
    Found: Boolean;
    Props: TStringList;
begin
    Designator := SchMcpGetString(RequestData, 'designator');
    if Designator = '' then
    begin
        Result := 'ERROR: designator is required';
        Exit;
    end;

    Names := TStringList.Create;
    Values := TStringList.Create;
    Updated := TStringList.Create;
    Created := TStringList.Create;
    try
        SchMcpGetStringArray(RequestData, 'parameter_names', Names);
        SchMcpGetStringArray(RequestData, 'parameter_values', Values);
        if (Names.Count = 0) or (Names.Count <> Values.Count) then
        begin
            Result := 'ERROR: parameter_names and parameter_values must be non-empty and the same length';
            Exit;
        end;
        for i := 0 to Names.Count - 1 do
            if Trim(Names[i]) = '' then
            begin
                Result := 'ERROR: parameter names must not be empty';
                Exit;
            end;

        Comp := SchEditFindComponent(SchDoc, Designator);
        if Comp = nil then
        begin
            Result := 'ERROR: Component not found on sheet: ' + Designator;
            Exit;
        end;

        for i := 0 to Names.Count - 1 do
        begin
            Found := False;
            Iter := Comp.SchIterator_Create;
            Iter.AddFilter_ObjectSet(MkSet(eParameter));
            Param := Iter.FirstSchObject;
            while Param <> nil do
            begin
                if UpperCase(Trim(Param.Name)) = UpperCase(Trim(Names[i])) then
                begin
                    SchEditBeginModify(Param);
                    Param.Text := Values[i];
                    SchEditEndModify(Param);
                    Found := True;
                    Break;
                end;
                Param := Iter.NextSchObject;
            end;
            Comp.SchIterator_Destroy(Iter);

            if Found then
                Updated.Add('"' + JSONEscapeString(Names[i]) + '"')
            else
            begin
                Param := SchServer.SchObjectFactory(eParameter, eCreate_Default);
                Param.Name := Trim(Names[i]);
                Param.Text := Values[i];
                Param.ParamType := eParameterType_String;
                Param.ReadOnlyState := eReadOnly_None;
                Param.IsHidden := True;
                Param.Location := Comp.Location;
                Comp.AddSchObject(Param);
                SchServer.RobotManager.SendMessage(Comp.I_ObjectAddress, c_BroadCast,
                    SCHM_PrimitiveRegistration, Param.I_ObjectAddress);
                Created.Add('"' + JSONEscapeString(Names[i]) + '"');
            end;
        end;

        Props := TStringList.Create;
        try
            AddJSONProperty(Props, 'designator', Comp.Designator.Text);
            Props.Add(BuildJSONArray(Updated, 'updated'));
            Props.Add(BuildJSONArray(Created, 'created_hidden'));
            Result := BuildJSONObject(Props);
        finally
            Props.Free;
        end;
    finally
        Created.Free;
        Updated.Free;
        Values.Free;
        Names.Free;
    end;
end;

// Place a symbol from a SchLib. Replicates the library symbol directly (the
// BuildCircuitFromSpec approach) instead of searching the sheet afterwards, so
// it can never grab and move an existing part with the same LibReference.
function SchEditPlaceComponent(SchDoc: ISch_Document; RequestData: TStringList): String;
var
    LibPath, LibRef, Designator: String;
    X, Y, Rot: Double;
    HasX, HasY, HasRot, ValidX, ValidY, ValidRot: Boolean;
    LibDoc: ISch_Document;
    ServerDoc: IServerDocument;
    Iter: ISch_Iterator;
    Prim, Found, Replica: ISch_Component;
    Props: TStringList;
begin
    LibPath := SchMcpNormalizePath(SchMcpGetString(RequestData, 'library_path'));
    LibRef := SchMcpGetString(RequestData, 'lib_reference');
    Designator := SchMcpGetString(RequestData, 'designator');
    X := SchMcpGetFloat(RequestData, 'x', HasX, ValidX);
    Y := SchMcpGetFloat(RequestData, 'y', HasY, ValidY);
    Rot := SchMcpGetFloat(RequestData, 'rotation', HasRot, ValidRot);

    if (LibPath = '') or (LibRef = '') or (Designator = '') then
    begin
        Result := 'ERROR: library_path, lib_reference and designator are required';
        Exit;
    end;
    if not (HasX and HasY) then
    begin
        Result := 'ERROR: x and y are required';
        Exit;
    end;
    if not (ValidX and ValidY and ValidRot) then
    begin
        Result := 'ERROR: x, y and rotation must be numbers';
        Exit;
    end;
    if not FileExists(LibPath) then
    begin
        Result := 'ERROR: Library not found: ' + LibPath;
        Exit;
    end;
    if SchEditFindComponent(SchDoc, Designator) <> nil then
    begin
        Result := 'ERROR: Designator already exists on sheet: ' + Designator;
        Exit;
    end;

    // Opening the library makes it the current document. Hold the target
    // sheet by reference and never register anything into LibDoc.
    LibDoc := SchServer.GetSchDocumentByPath(LibPath);
    if LibDoc = nil then
    begin
        ServerDoc := Client.OpenDocument('SchLib', LibPath);
        if ServerDoc <> nil then
            Client.ShowDocument(ServerDoc);
        Sleep(1200);
        LibDoc := SchServer.GetSchDocumentByPath(LibPath);
    end;
    if LibDoc = nil then
    begin
        Result := 'ERROR: Could not open library: ' + LibPath;
        Exit;
    end;

    Found := nil;
    Iter := LibDoc.SchLibIterator_Create;
    Iter.AddFilter_ObjectSet(MkSet(eSchComponent));
    Prim := Iter.FirstSchObject;
    while Prim <> nil do
    begin
        if UpperCase(Prim.LibReference) = UpperCase(LibRef) then
        begin
            Found := Prim;
            Break;
        end;
        Prim := Iter.NextSchObject;
    end;
    LibDoc.SchIterator_Destroy(Iter);
    if Found = nil then
    begin
        Result := 'ERROR: Symbol "' + LibRef + '" not found in ' + LibPath;
        Exit;
    end;

    Replica := Found.Replicate;
    Replica.Designator.Text := Designator;
    if HasRot then
        Replica.Orientation := SchEditRotationFromDeg(Rot);
    SchEditRegister(SchDoc, Replica);
    Replica.MoveByXY(MilsToCoord(X) - Replica.Location.X, MilsToCoord(Y) - Replica.Location.Y);

    Props := TStringList.Create;
    try
        AddJSONProperty(Props, 'designator', Replica.Designator.Text);
        AddJSONProperty(Props, 'lib_reference', Replica.LibReference);
        AddJSONNumber(Props, 'x', CoordToMils(Replica.Location.X));
        AddJSONNumber(Props, 'y', CoordToMils(Replica.Location.Y));
        AddJSONInteger(Props, 'rotation', SchMcpOrientationDeg(Replica.Orientation));
        Props.Add('"pins": ' + SchMcpPinsJSON(Replica));
        Result := BuildJSONObject(Props);
    finally
        Props.Free;
    end;
end;

// One polyline wire or bus through every point (the editor's own model),
// not one object per segment.
function SchEditAddPolyline(SchDoc: ISch_Document; RequestData: TStringList; IsBus: Boolean): String;
var
    Coords, Props: TStringList;
    Obj: ISch_Polyline;
    i, V: Integer;
begin
    Coords := TStringList.Create;
    try
        Result := SchEditParsePoints(SchMcpGetString(RequestData, 'points'), 2, Coords);
        if Result <> '' then
            Exit;

        if IsBus then
            Obj := SchServer.SchObjectFactory(eBus, eCreate_GlobalCopy)
        else
            Obj := SchServer.SchObjectFactory(eWire, eCreate_GlobalCopy);
        if Obj = nil then
        begin
            Result := 'ERROR: Could not create object';
            Exit;
        end;

        Obj.Location := Point(SchEditCoord(Coords, 0), SchEditCoord(Coords, 1));
        V := 0;
        i := 0;
        while i < Coords.Count do
        begin
            V := V + 1;
            Obj.InsertVertex := V;
            Obj.SetState_Vertex(V, Point(SchEditCoord(Coords, i), SchEditCoord(Coords, i + 1)));
            i := i + 2;
        end;
        SchEditRegister(SchDoc, Obj);

        Props := TStringList.Create;
        try
            Props.Add('"vertices": ' + SchMcpVerticesJSON(Obj));
            Result := BuildJSONObject(Props);
        finally
            Props.Free;
        end;
    finally
        Coords.Free;
    end;
end;

function SchEditAddBusEntry(SchDoc: ISch_Document; RequestData: TStringList): String;
var
    Coords, Props: TStringList;
    Obj: ISch_BusEntry;
begin
    Coords := TStringList.Create;
    try
        Result := SchEditParsePoints(SchMcpGetString(RequestData, 'points'), 2, Coords);
        if Result <> '' then
            Exit;
        if Coords.Count <> 4 then
        begin
            Result := 'ERROR: a bus entry takes exactly 2 points';
            Exit;
        end;

        Obj := SchServer.SchObjectFactory(eBusEntry, eCreate_GlobalCopy);
        if Obj = nil then
        begin
            Result := 'ERROR: Could not create bus entry';
            Exit;
        end;
        Obj.Location := Point(SchEditCoord(Coords, 0), SchEditCoord(Coords, 1));
        Obj.Corner := Point(SchEditCoord(Coords, 2), SchEditCoord(Coords, 3));
        SchEditRegister(SchDoc, Obj);

        Props := TStringList.Create;
        try
            AddJSONNumber(Props, 'x1', CoordToMils(Obj.Location.X));
            AddJSONNumber(Props, 'y1', CoordToMils(Obj.Location.Y));
            AddJSONNumber(Props, 'x2', CoordToMils(Obj.Corner.X));
            AddJSONNumber(Props, 'y2', CoordToMils(Obj.Corner.Y));
            Result := BuildJSONObject(Props);
        finally
            Props.Free;
        end;
    finally
        Coords.Free;
    end;
end;

// Junction dot. Wires that merely cross are NOT connected unless a junction
// sits on the crossing.
function SchEditAddJunction(SchDoc: ISch_Document; RequestData: TStringList): String;
var
    X, Y: Double;
    HasX, HasY, ValidX, ValidY: Boolean;
    Obj: ISch_Junction;
    Props: TStringList;
begin
    X := SchMcpGetFloat(RequestData, 'x', HasX, ValidX);
    Y := SchMcpGetFloat(RequestData, 'y', HasY, ValidY);
    if not (HasX and HasY) then
    begin
        Result := 'ERROR: x and y are required';
        Exit;
    end;
    if not (ValidX and ValidY) then
    begin
        Result := 'ERROR: x and y must be numbers';
        Exit;
    end;

    Obj := SchServer.SchObjectFactory(eJunction, eCreate_GlobalCopy);
    if Obj = nil then
    begin
        Result := 'ERROR: Could not create junction';
        Exit;
    end;
    Obj.Location := Point(MilsToCoord(X), MilsToCoord(Y));
    SchEditRegister(SchDoc, Obj);

    Props := TStringList.Create;
    try
        AddJSONNumber(Props, 'x', CoordToMils(Obj.Location.X));
        AddJSONNumber(Props, 'y', CoordToMils(Obj.Location.Y));
        Result := BuildJSONObject(Props);
    finally
        Props.Free;
    end;
end;

// Net labels, power ports and text labels: a point object with text.
function SchEditAddPointObject(SchDoc: ISch_Document; RequestData: TStringList; Action: String): String;
var
    Txt, StyleName: String;
    X, Y, Rot: Double;
    HasX, HasY, HasRot, ValidX, ValidY, ValidRot: Boolean;
    Style: Integer;
    Obj: ISch_GraphicalObject;
    Props: TStringList;
begin
    if Action = 'add_text' then
        Txt := SchMcpGetString(RequestData, 'text')
    else
        Txt := SchMcpGetString(RequestData, 'net_name');
    X := SchMcpGetFloat(RequestData, 'x', HasX, ValidX);
    Y := SchMcpGetFloat(RequestData, 'y', HasY, ValidY);
    Rot := SchMcpGetFloat(RequestData, 'rotation', HasRot, ValidRot);

    if Trim(Txt) = '' then
    begin
        if Action = 'add_text' then
            Result := 'ERROR: text is required'
        else
            Result := 'ERROR: net_name is required';
        Exit;
    end;
    if not (HasX and HasY) then
    begin
        Result := 'ERROR: x and y are required';
        Exit;
    end;
    if not (ValidX and ValidY and ValidRot) then
    begin
        Result := 'ERROR: x, y and rotation must be numbers';
        Exit;
    end;

    if Action = 'add_power_port' then
    begin
        StyleName := SchMcpGetString(RequestData, 'style');
        if StyleName = '' then
        begin
            if Pos('GND', UpperCase(Txt)) > 0 then
                StyleName := 'gnd_power'
            else
                StyleName := 'bar';
        end;
        if not SchEditParsePowerStyle(StyleName, Style) then
        begin
            Result := 'ERROR: unknown power port style: ' + StyleName;
            Exit;
        end;
        Obj := SchServer.SchObjectFactory(ePowerObject, eCreate_GlobalCopy);
    end
    else if Action = 'add_net_label' then
        Obj := SchServer.SchObjectFactory(eNetLabel, eCreate_GlobalCopy)
    else
        Obj := SchServer.SchObjectFactory(eLabel, eCreate_GlobalCopy);

    if Obj = nil then
    begin
        Result := 'ERROR: Could not create object';
        Exit;
    end;

    Obj.Location := Point(MilsToCoord(X), MilsToCoord(Y));
    Obj.Orientation := SchEditRotationFromDeg(Rot);
    Obj.Text := Txt;
    if Action = 'add_power_port' then
    begin
        Obj.Style := Style;
        Obj.ShowNetName := SchMcpGetBool(RequestData, 'show_net_name', True);
    end;
    SchEditRegister(SchDoc, Obj);

    Props := TStringList.Create;
    try
        AddJSONProperty(Props, 'text', Obj.Text);
        if Action = 'add_power_port' then
            AddJSONProperty(Props, 'style', SchMcpPowerStyleName(Obj.Style));
        AddJSONNumber(Props, 'x', CoordToMils(Obj.Location.X));
        AddJSONNumber(Props, 'y', CoordToMils(Obj.Location.Y));
        AddJSONInteger(Props, 'rotation', SchMcpOrientationDeg(Obj.Orientation));
        Result := BuildJSONObject(Props);
    finally
        Props.Free;
    end;
end;

{..............................................................................}
{ Entry point for the 'schematic_edit' bridge command.                         }
{..............................................................................}
function ExecuteSchematicEdit(RequestData: TStringList): String;
var
    Action, SheetPath, Err, Inner: String;
    SchDoc: ISch_Document;
    ServerDoc: IServerDocument;
    Props: TStringList;
begin
    Action := LowerCase(SchMcpGetString(RequestData, 'action'));
    if (Action <> 'move_component') and (Action <> 'set_component_parameters') and
       (Action <> 'place_component') and (Action <> 'add_wire') and (Action <> 'add_bus') and
       (Action <> 'add_bus_entry') and (Action <> 'add_net_label') and
       (Action <> 'add_power_port') and (Action <> 'add_text') and (Action <> 'add_junction') then
    begin
        Result := 'ERROR: Unknown schematic_edit action: ' + Action;
        Exit;
    end;

    SheetPath := SchMcpNormalizePath(SchMcpGetString(RequestData, 'schematic_path'));
    Err := SchMcpResolveSheet(SheetPath, SchDoc);
    if Err <> '' then
    begin
        Result := Err;
        Exit;
    end;

    SchServer.ProcessControl.PreProcess(SchDoc, '');
    try
        if Action = 'move_component' then
            Inner := SchEditMoveComponent(SchDoc, RequestData)
        else if Action = 'set_component_parameters' then
            Inner := SchEditSetParameters(SchDoc, RequestData)
        else if Action = 'place_component' then
            Inner := SchEditPlaceComponent(SchDoc, RequestData)
        else if Action = 'add_wire' then
            Inner := SchEditAddPolyline(SchDoc, RequestData, False)
        else if Action = 'add_bus' then
            Inner := SchEditAddPolyline(SchDoc, RequestData, True)
        else if Action = 'add_bus_entry' then
            Inner := SchEditAddBusEntry(SchDoc, RequestData)
        else if Action = 'add_junction' then
            Inner := SchEditAddJunction(SchDoc, RequestData)
        else
            Inner := SchEditAddPointObject(SchDoc, RequestData, Action);
    finally
        SchServer.ProcessControl.PostProcess(SchDoc, '');
    end;
    SchDoc.GraphicallyInvalidate;

    // place_component may have brought a library to the front; show the
    // edited sheet so the user sees the change.
    ServerDoc := Client.GetDocumentByPath(SheetPath);
    if ServerDoc <> nil then
        Client.ShowDocument(ServerDoc);

    if Pos('ERROR:', Inner) = 1 then
    begin
        Result := Inner;
        Exit;
    end;

    Props := TStringList.Create;
    try
        AddJSONProperty(Props, 'action', Action);
        AddJSONProperty(Props, 'sheet', SheetPath);
        AddJSONBoolean(Props, 'saved', False);
        Props.Add('"details": ' + Inner);
        Result := BuildJSONObject(Props);
    finally
        Props.Free;
    end;
end;
