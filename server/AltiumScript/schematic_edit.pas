{..............................................................................}
{ schematic_edit.pas                                                           }
{                                                                              }
{ The schematic_edit command: one edit action on an EXISTING schematic sheet.  }
{ Actions: move_component, set_component_parameters, set_component_text,      }
{ place_component,                                                             }
{ add_wire, add_bus, add_bus_entry, add_junction, add_net_label,              }
{ add_power_port, add_port, add_text, and create_sheet (a new file).          }
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

function SchEditParseJustification(S: String; var Just: Integer): Boolean;
begin
    Result := True;
    S := LowerCase(Trim(S));
    if S = 'bottom_left' then Just := 0
    else if S = 'bottom_center' then Just := 1
    else if S = 'bottom_right' then Just := 2
    else if S = 'center_left' then Just := 3
    else if S = 'center' then Just := 4
    else if S = 'center_right' then Just := 5
    else if S = 'top_left' then Just := 6
    else if S = 'top_center' then Just := 7
    else if S = 'top_right' then Just := 8
    else Result := False;
end;

// Place component texts: the designator ("Designator") or any parameter by
// name. Parallel arrays, one entry per text; '' leaves that property alone.
// Everything is validated before anything changes.
function SchEditSetComponentText(SchDoc: ISch_Document; RequestData: TStringList): String;
var
    Designator: String;
    Comp: ISch_Component;
    Names, Xs, Ys, Visibles, Rots, Justs, Done, Props: TStringList;
    Iter: ISch_Iterator;
    Param: ISch_Parameter;
    Txt: ISch_GraphicalObject;
    i, Just: Integer;
    NewX, NewY: Integer;
begin
    Designator := SchMcpGetString(RequestData, 'designator');
    if Designator = '' then
    begin
        Result := 'ERROR: designator is required';
        Exit;
    end;

    Names := TStringList.Create;
    Xs := TStringList.Create;
    Ys := TStringList.Create;
    Visibles := TStringList.Create;
    Rots := TStringList.Create;
    Justs := TStringList.Create;
    Done := TStringList.Create;
    try
        SchMcpGetStringArray(RequestData, 'text_names', Names);
        SchMcpGetStringArray(RequestData, 'text_x', Xs);
        SchMcpGetStringArray(RequestData, 'text_y', Ys);
        SchMcpGetStringArray(RequestData, 'text_visible', Visibles);
        SchMcpGetStringArray(RequestData, 'text_rotation', Rots);
        SchMcpGetStringArray(RequestData, 'text_justification', Justs);
        if (Names.Count = 0) or (Xs.Count <> Names.Count) or (Ys.Count <> Names.Count) or
           (Visibles.Count <> Names.Count) or (Rots.Count <> Names.Count) or (Justs.Count <> Names.Count) then
        begin
            Result := 'ERROR: text arrays must be non-empty and the same length';
            Exit;
        end;

        Comp := SchEditFindComponent(SchDoc, Designator);
        if Comp = nil then
        begin
            Result := 'ERROR: Component not found on sheet: ' + Designator;
            Exit;
        end;

        // Validate every entry first.
        for i := 0 to Names.Count - 1 do
        begin
            if ((Xs[i] <> '') and not SchMcpIsNumber(Xs[i])) or ((Ys[i] <> '') and not SchMcpIsNumber(Ys[i])) or
               ((Rots[i] <> '') and not SchMcpIsNumber(Rots[i])) then
            begin
                Result := 'ERROR: x, y and rotation must be numbers (text "' + Names[i] + '")';
                Exit;
            end;
            if (Justs[i] <> '') and not SchEditParseJustification(Justs[i], Just) then
            begin
                Result := 'ERROR: unknown justification "' + Justs[i] + '"';
                Exit;
            end;
            if UpperCase(Names[i]) <> 'DESIGNATOR' then
            begin
                Txt := nil;
                Iter := Comp.SchIterator_Create;
                Iter.AddFilter_ObjectSet(MkSet(eParameter));
                Param := Iter.FirstSchObject;
                while Param <> nil do
                begin
                    if UpperCase(Param.Name) = UpperCase(Names[i]) then
                        Txt := Param;
                    Param := Iter.NextSchObject;
                end;
                Comp.SchIterator_Destroy(Iter);
                if Txt = nil then
                begin
                    Result := 'ERROR: ' + Designator + ' has no parameter "' + Names[i] + '"';
                    Exit;
                end;
            end;
        end;

        for i := 0 to Names.Count - 1 do
        begin
            if UpperCase(Names[i]) = 'DESIGNATOR' then
                Txt := Comp.Designator
            else
            begin
                Txt := nil;
                Iter := Comp.SchIterator_Create;
                Iter.AddFilter_ObjectSet(MkSet(eParameter));
                Param := Iter.FirstSchObject;
                while Param <> nil do
                begin
                    if UpperCase(Param.Name) = UpperCase(Names[i]) then
                        Txt := Param;
                    Param := Iter.NextSchObject;
                end;
                Comp.SchIterator_Destroy(Iter);
            end;

            SchEditBeginModify(Txt);
            if (Xs[i] <> '') or (Ys[i] <> '') then
            begin
                NewX := Txt.Location.X;
                NewY := Txt.Location.Y;
                if Xs[i] <> '' then NewX := MilsToCoord(SafeStrToFloat(Xs[i]));
                if Ys[i] <> '' then NewY := MilsToCoord(SafeStrToFloat(Ys[i]));
                Txt.Autoposition := False;
                Txt.MoveToXY(NewX, NewY);
            end;
            if Rots[i] <> '' then
            begin
                Txt.Autoposition := False;
                Txt.Orientation := SchEditRotationFromDeg(SafeStrToFloat(Rots[i]));
            end;
            if Justs[i] <> '' then
            begin
                SchEditParseJustification(Justs[i], Just);
                Txt.Autoposition := False;
                Txt.Justification := Just;
            end;
            if Visibles[i] <> '' then
                Txt.IsHidden := not ((LowerCase(Visibles[i]) = 'true') or (Visibles[i] = '1'));
            SchEditEndModify(Txt);
            Done.Add('"' + JSONEscapeString(Names[i]) + '": ' + SchMcpTextPlacementJSON(Txt));
        end;

        Props := TStringList.Create;
        try
            AddJSONProperty(Props, 'designator', Comp.Designator.Text);
            Props.Add('"text": ' + BuildJSONObject(Done, 1));
            Result := BuildJSONObject(Props);
        finally
            Props.Free;
        end;
    finally
        Done.Free;
        Justs.Free;
        Rots.Free;
        Visibles.Free;
        Ys.Free;
        Xs.Free;
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

// Sheet port. Location is one end; it also connects at the end Width away
// (along X for left/right/none styles, along Y for top/bottom styles).
function SchEditAddPort(SchDoc: ISch_Document; RequestData: TStringList): String;
var
    Name, StyleName, IOName: String;
    X, Y, W: Double;
    HasX, HasY, HasW, ValidX, ValidY, ValidW: Boolean;
    Style, IOType: Integer;
    Obj: ISch_Port;
    Props: TStringList;
begin
    Name := SchMcpGetString(RequestData, 'name');
    X := SchMcpGetFloat(RequestData, 'x', HasX, ValidX);
    Y := SchMcpGetFloat(RequestData, 'y', HasY, ValidY);
    W := SchMcpGetFloat(RequestData, 'width', HasW, ValidW);
    StyleName := LowerCase(SchMcpGetString(RequestData, 'style'));
    IOName := LowerCase(SchMcpGetString(RequestData, 'io_type'));

    if Trim(Name) = '' then
    begin
        Result := 'ERROR: name is required';
        Exit;
    end;
    if not (HasX and HasY) then
    begin
        Result := 'ERROR: x and y are required';
        Exit;
    end;
    if not (ValidX and ValidY and ValidW) then
    begin
        Result := 'ERROR: x, y and width must be numbers';
        Exit;
    end;
    if not HasW then W := 600;
    if W <= 0 then
    begin
        Result := 'ERROR: width must be positive';
        Exit;
    end;

    if (StyleName = '') or (StyleName = 'right') then Style := ePortRight
    else if StyleName = 'none' then Style := ePortNone
    else if StyleName = 'left' then Style := ePortLeft
    else if StyleName = 'left_right' then Style := ePortLeftRight
    else if StyleName = 'top' then Style := ePortTop
    else if StyleName = 'bottom' then Style := ePortBottom
    else if StyleName = 'top_bottom' then Style := ePortTopBottom
    else
    begin
        Result := 'ERROR: unknown port style: ' + StyleName;
        Exit;
    end;

    if (IOName = '') or (IOName = 'unspecified') then IOType := ePortUnspecified
    else if IOName = 'output' then IOType := ePortOutput
    else if IOName = 'input' then IOType := ePortInput
    else if IOName = 'bidirectional' then IOType := ePortBidirectional
    else
    begin
        Result := 'ERROR: unknown port io_type: ' + IOName;
        Exit;
    end;

    Obj := SchServer.SchObjectFactory(ePort, eCreate_GlobalCopy);
    if Obj = nil then
    begin
        Result := 'ERROR: Could not create port';
        Exit;
    end;
    Obj.Location := Point(MilsToCoord(X), MilsToCoord(Y));
    Obj.Name := Name;
    Obj.IOType := IOType;
    Obj.Style := Style;
    // Fixed size: with AutoSize on, Altium stretches the port to fit its name,
    // which moves the far connection point away from the requested width.
    Obj.AutoSize := False;
    Obj.Width := MilsToCoord(W);
    SchEditRegister(SchDoc, Obj);

    Props := TStringList.Create;
    try
        AddJSONProperty(Props, 'name', Obj.Name);
        AddJSONProperty(Props, 'io_type', SchMcpPortIOTypeName(Obj.IOType));
        AddJSONProperty(Props, 'style', SchMcpPortStyleName(Obj.Style));
        AddJSONNumber(Props, 'x', CoordToMils(Obj.Location.X));
        AddJSONNumber(Props, 'y', CoordToMils(Obj.Location.Y));
        AddJSONNumber(Props, 'width', CoordToMils(Obj.Width));
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
{ create_sheet: a NEW blank sheet, optionally formatted like another sheet.    }
{ The only action that writes a file, and it never overwrites one.             }
{..............................................................................}

function SchEditInRegion(Obj: ISch_GraphicalObject; L, B, R, T: Integer): Boolean;
var
    Tol: Integer;
begin
    Tol := MilsToCoord(10);
    // A label's extent depends on its displayed value (a long "=Parameter"
    // can spill past the box), so labels count by their anchor point.
    if Obj.ObjectId = eLabel then
        Result := (Obj.Location.X >= L - Tol) and (Obj.Location.X <= R + Tol) and
                  (Obj.Location.Y >= B - Tol) and (Obj.Location.Y <= T + Tol)
    else
        Result := (Obj.BoundingRectangle.Left >= L - Tol) and (Obj.BoundingRectangle.Right <= R + Tol) and
                  (Obj.BoundingRectangle.Bottom >= B - Tol) and (Obj.BoundingRectangle.Top <= T + Tol);
end;

// Copy sheet size, grids and border settings from Src to Dst.
procedure SchEditCopySheetSettings(Src, Dst: ISch_Document);
begin
    Dst.SheetStyle := Src.SheetStyle;
    Dst.UseCustomSheet := Src.UseCustomSheet;
    Dst.CustomX := Src.CustomX;
    Dst.CustomY := Src.CustomY;
    Dst.SnapGridOn := Src.SnapGridOn;
    Dst.SnapGridSize := Src.SnapGridSize;
    Dst.VisibleGridOn := Src.VisibleGridOn;
    Dst.VisibleGridSize := Src.VisibleGridSize;
    Dst.BorderOn := Src.BorderOn;
    Dst.TitleBlockOn := Src.TitleBlockOn;
    if Src.TemplateFileName <> '' then
        Dst.TemplateFileName := Src.TemplateFileName;
end;

// Copy document parameters that have a value ('*' means unset). Adds the
// copied names (JSON strings) to Names and returns how many were copied.
function SchEditCopySheetParameters(Src, Dst: ISch_Document; Names: TStringList): Integer;
var
    SrcIter, DstIter: ISch_Iterator;
    SrcParam, DstParam: ISch_Parameter;
begin
    Result := 0;
    SrcIter := Src.SchIterator_Create;
    SrcIter.SetState_IterationDepth(eIterateFirstLevel);
    SrcIter.AddFilter_ObjectSet(MkSet(eParameter));
    SrcParam := SrcIter.FirstSchObject;
    while SrcParam <> nil do
    begin
        if (SrcParam.Text <> '*') and (SrcParam.Text <> '') then
        begin
            DstIter := Dst.SchIterator_Create;
            DstIter.SetState_IterationDepth(eIterateFirstLevel);
            DstIter.AddFilter_ObjectSet(MkSet(eParameter));
            DstParam := DstIter.FirstSchObject;
            while DstParam <> nil do
            begin
                if UpperCase(DstParam.Name) = UpperCase(SrcParam.Name) then
                    Break;
                DstParam := DstIter.NextSchObject;
            end;
            Dst.SchIterator_Destroy(DstIter);

            if DstParam <> nil then
                DstParam.Text := SrcParam.Text
            else
            begin
                DstParam := SrcParam.Replicate;
                SchEditRegister(Dst, DstParam);
            end;
            Names.Add('"' + JSONEscapeString(SrcParam.Name) + '"');
            Result := Result + 1;
        end;
        SrcParam := SrcIter.NextSchObject;
    end;
    Src.SchIterator_Destroy(SrcIter);
end;

function SchEditCreateSheet(RequestData: TStringList): String;
var
    NewPath, FormatPath, RegionCSV, Err: String;
    FormatDoc, NewDoc: ISch_Document;
    ServerDoc: IServerDocument;
    Proj: IProject;
    Coords, ParamNames, Props: TStringList;
    Iter: ISch_Iterator;
    Obj, Dup: ISch_GraphicalObject;
    HasRegion: Boolean;
    L, B, R, T, Copied, ParamCount: Integer;
begin
    NewPath := SchMcpNormalizePath(SchMcpGetString(RequestData, 'schematic_path'));
    FormatPath := SchMcpNormalizePath(SchMcpGetString(RequestData, 'copy_format_from'));
    RegionCSV := SchMcpGetString(RequestData, 'title_block_region');

    if LowerCase(ExtractFileExt(NewPath)) <> '.schdoc' then
    begin
        Result := 'ERROR: schematic_path must be a .SchDoc file: ' + NewPath;
        Exit;
    end;
    if FileExists(NewPath) then
    begin
        Result := 'ERROR: File already exists (create_sheet never overwrites): ' + NewPath;
        Exit;
    end;
    if not DirectoryExists(ExtractFilePath(NewPath)) then
    begin
        Result := 'ERROR: Folder does not exist: ' + ExtractFilePath(NewPath);
        Exit;
    end;

    HasRegion := RegionCSV <> '';
    if HasRegion then
    begin
        Coords := TStringList.Create;
        try
            Err := SchEditParsePoints(RegionCSV, 2, Coords);
            if (Err = '') and (Coords.Count <> 4) then
                Err := 'ERROR: title_block_region takes exactly 4 numbers';
            if Err <> '' then
            begin
                Result := Err;
                Exit;
            end;
            L := SchEditCoord(Coords, 0);
            R := SchEditCoord(Coords, 2);
            if R < L then begin R := L; L := SchEditCoord(Coords, 2); end;
            B := SchEditCoord(Coords, 1);
            T := SchEditCoord(Coords, 3);
            if T < B then begin T := B; B := SchEditCoord(Coords, 3); end;
        finally
            Coords.Free;
        end;
    end;

    FormatDoc := nil;
    if FormatPath <> '' then
    begin
        Err := SchMcpResolveSheet(FormatPath, FormatDoc);
        if Err <> '' then
        begin
            Result := Err;
            Exit;
        end;
    end;

    ServerDoc := CreateNewDocumentFromDocumentKind('SCH');
    NewDoc := SchServer.GetCurrentSchDocument;
    if (ServerDoc = nil) or (NewDoc = nil) or (NewDoc.ObjectID <> 32) then
    begin
        Result := 'ERROR: Could not create a new schematic document';
        Exit;
    end;

    // A new document can be adopted by the focused project; a created sheet
    // must not change the user's project (same rule as BuildCircuitFromSpec).
    Proj := GetWorkspace.DM_FocusedProject;
    if Proj <> nil then
        if Pos('Free Documents', Proj.DM_ProjectFileName) = 0 then
            Proj.DM_RemoveSourceDocument(NewDoc.DocumentName);

    ParamNames := TStringList.Create;
    Props := TStringList.Create;
    try
        Copied := 0;
        ParamCount := 0;
        if FormatDoc <> nil then
        begin
            SchServer.ProcessControl.PreProcess(NewDoc, '');
            SchEditCopySheetSettings(FormatDoc, NewDoc);
            ParamCount := SchEditCopySheetParameters(FormatDoc, NewDoc, ParamNames);

            // Auto-detect the title block: drawing graphics in the
            // bottom-right quarter of the sheet.
            if not HasRegion then
            begin
                L := 2000000000; B := 2000000000; R := -2000000000; T := -2000000000;
                Iter := FormatDoc.SchIterator_Create;
                Iter.SetState_IterationDepth(eIterateFirstLevel);
                Iter.AddFilter_ObjectSet(MkSet(ePolyline, eLine, eRectangle, eRoundRectangle, eImage, eTextFrame));
                Obj := Iter.FirstSchObject;
                while Obj <> nil do
                begin
                    if (Obj.BoundingRectangle.Left >= FormatDoc.GetState_SheetSizeX div 2) and
                       (Obj.BoundingRectangle.Top <= FormatDoc.GetState_SheetSizeY div 2) then
                    begin
                        HasRegion := True;
                        if Obj.BoundingRectangle.Left < L then L := Obj.BoundingRectangle.Left;
                        if Obj.BoundingRectangle.Bottom < B then B := Obj.BoundingRectangle.Bottom;
                        if Obj.BoundingRectangle.Right > R then R := Obj.BoundingRectangle.Right;
                        if Obj.BoundingRectangle.Top > T then T := Obj.BoundingRectangle.Top;
                    end;
                    Obj := Iter.NextSchObject;
                end;
                FormatDoc.SchIterator_Destroy(Iter);
            end;

            if HasRegion then
            begin
                Iter := FormatDoc.SchIterator_Create;
                Iter.SetState_IterationDepth(eIterateFirstLevel);
                Iter.AddFilter_ObjectSet(MkSet(ePolyline, eLine, eRectangle, eRoundRectangle, eImage, eTextFrame,
                    eLabel, eArc, eEllipse, ePolygon, eBezier));
                Obj := Iter.FirstSchObject;
                while Obj <> nil do
                begin
                    if SchEditInRegion(Obj, L, B, R, T) then
                    begin
                        Dup := Obj.Replicate;
                        SchEditRegister(NewDoc, Dup);
                        Copied := Copied + 1;
                    end;
                    Obj := Iter.NextSchObject;
                end;
                FormatDoc.SchIterator_Destroy(Iter);
            end;
            SchServer.ProcessControl.PostProcess(NewDoc, '');
            NewDoc.GraphicallyInvalidate;
        end;

        ServerDoc.SetFileName(NewPath);
        ServerDoc.SetModified(True);
        ServerDoc.DoFileSave('');
        if not FileExists(NewPath) then
        begin
            Result := 'ERROR: Sheet was created but could not be saved to ' + NewPath;
            Exit;
        end;

        AddJSONProperty(Props, 'created', NewPath);
        AddJSONProperty(Props, 'format_copied_from', FormatPath);
        AddJSONNumber(Props, 'sheet_size_x', CoordToMils(NewDoc.GetState_SheetSizeX));
        AddJSONNumber(Props, 'sheet_size_y', CoordToMils(NewDoc.GetState_SheetSizeY));
        AddJSONProperty(Props, 'template_file', NewDoc.TemplateFileName);
        Props.Add(BuildJSONArray(ParamNames, 'sheet_parameters_copied'));
        if HasRegion then
            Props.Add('"title_block_region": [' + IntToStr(CoordToMils(L)) + ', ' + IntToStr(CoordToMils(B)) +
                      ', ' + IntToStr(CoordToMils(R)) + ', ' + IntToStr(CoordToMils(T)) + ']')
        else
            Props.Add('"title_block_region": null');
        AddJSONInteger(Props, 'title_block_objects_copied', Copied);
        Result := BuildJSONObject(Props);
    finally
        Props.Free;
        ParamNames.Free;
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
    if Action = 'create_sheet' then
    begin
        Result := SchEditCreateSheet(RequestData);
        Exit;
    end;
    if (Action <> 'move_component') and (Action <> 'set_component_parameters') and
       (Action <> 'place_component') and (Action <> 'add_wire') and (Action <> 'add_bus') and
       (Action <> 'add_bus_entry') and (Action <> 'add_net_label') and
       (Action <> 'add_power_port') and (Action <> 'add_text') and (Action <> 'add_junction') and
       (Action <> 'add_port') and (Action <> 'set_component_text') then
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
        else if Action = 'set_component_text' then
            Inner := SchEditSetComponentText(SchDoc, RequestData)
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
        else if Action = 'add_port' then
            Inner := SchEditAddPort(SchDoc, RequestData)
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
