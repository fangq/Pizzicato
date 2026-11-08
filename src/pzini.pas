{ .picasa.ini reader/writer and the Picasa filter-chain model.

  Pizzicato never modifies image files. Edits live in the per-folder
  .picasa.ini exactly where Picasa keeps them, so edits made in Picasa show
  up here and vice versa. Unknown sections and keys are preserved verbatim. }
unit pzini;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils;

type
  { One filter of a chain, e.g. "finetune2=1,0.4,0,0,00000000,0" }
  TPzFilter = record
    Name: string;
    Args: array of string;   // arguments after the leading enable flag
  end;
  TPzChain = array of TPzFilter;

  TPzIniSection = class
    Name: string;
    Lines: TStringList;      // key=value in file order
    constructor Create(const AName: string);
    destructor Destroy; override;
  end;

  { TPzIni }

  TPzIni = class
  private
    FPath: string;
    FSections: TList;
    FCRLF: Boolean;
    FDirty: Boolean;
    function GetCount: Integer;
    function GetSection(i: Integer): TPzIniSection;
  public
    constructor Create(const APath: string);
    destructor Destroy; override;
    procedure Load;
    function Save: Boolean;
    function Find(const ASection: string; ACreate: Boolean = False): TPzIniSection;
    function ReadValue(const ASection, AKey: string;
      const ADefault: string = ''): string;
    procedure WriteValue(const ASection, AKey, AValue: string);
    procedure DeleteKey(const ASection, AKey: string);
    property Path: string read FPath;
    property Dirty: Boolean read FDirty write FDirty;
    property Count: Integer read GetCount;
    property Sections[i: Integer]: TPzIniSection read GetSection;
  end;

function ParseChain(const S: string): TPzChain;
function ChainToString(const C: TPzChain): string;
function MakeFilter(const AName: string; const AArgs: array of string): TPzFilter;
function FArg(const F: TPzFilter; i: Integer; ADefault: Double = 0): Double;
function FmtF(v: Double): string;
procedure ChainAppend(var C: TPzChain; const F: TPzFilter);
function ChainPop(var C: TPzChain): TPzFilter;
function ParseRotate(const S: string): Integer;   // "rotate(3)" -> 3
function RotateToString(q: Integer): string;
{ crop64 hex <-> normalised rectangle }
function Crop64Decode(const Hex: string; out L, T, R, B: Double): Boolean;
function Crop64Encode(L, T, R, B: Double): string;

implementation

var
  FS: TFormatSettings;

{ TPzIniSection }

constructor TPzIniSection.Create(const AName: string);
begin
  Name := AName;
  Lines := TStringList.Create;
  Lines.NameValueSeparator := '=';
end;

destructor TPzIniSection.Destroy;
begin
  Lines.Free;
  inherited Destroy;
end;

{ TPzIni }

constructor TPzIni.Create(const APath: string);
begin
  FPath := APath;
  FSections := TList.Create;
  FCRLF := True; // Picasa writes CRLF
end;

destructor TPzIni.Destroy;
var
  i: Integer;
begin
  for i := 0 to FSections.Count - 1 do
    TPzIniSection(FSections[i]).Free;
  FSections.Free;
  inherited Destroy;
end;

function TPzIni.GetCount: Integer;
begin
  Result := FSections.Count;
end;

function TPzIni.GetSection(i: Integer): TPzIniSection;
begin
  Result := TPzIniSection(FSections[i]);
end;

procedure TPzIni.Load;
var
  SL: TStringList;
  i: Integer;
  L: string;
  Cur: TPzIniSection;
  Raw: string;
  F: TFileStream;
begin
  if not FileExists(FPath) then
    Exit;
  SL := TStringList.Create;
  try
    try
      F := TFileStream.Create(FPath, fmOpenRead or fmShareDenyNone);
      try
        SetLength(Raw, F.Size);
        if F.Size > 0 then
          F.ReadBuffer(Raw[1], F.Size);
      finally
        F.Free;
      end;
    except
      Exit;
    end;
    FCRLF := (Pos(#13#10, Raw) > 0) or (Raw = '');
    SL.Text := Raw;
    Cur := nil;
    for i := 0 to SL.Count - 1 do
    begin
      L := Trim(SL[i]);
      if L = '' then
        Continue;
      if (L[1] = '[') and (L[Length(L)] = ']') then
      begin
        Cur := Find(Copy(L, 2, Length(L) - 2), True);
      end
      else if Cur <> nil then
        Cur.Lines.Add(L);
    end;
  finally
    SL.Free;
  end;
  FDirty := False;
end;

function TPzIni.Save: Boolean;
var
  S: string;
  i, j: Integer;
  Sec: TPzIniSection;
  EOL, Tmp: string;
  F: TFileStream;
begin
  Result := True;
  if not FDirty then
    Exit;
  if FCRLF then
    EOL := #13#10
  else
    EOL := #10;
  S := '';
  for i := 0 to FSections.Count - 1 do
  begin
    Sec := TPzIniSection(FSections[i]);
    { Picasa writes empty sections too; keep them so files round-trip }
    S := S + '[' + Sec.Name + ']' + EOL;
    for j := 0 to Sec.Lines.Count - 1 do
      S := S + Sec.Lines[j] + EOL;
  end;
  { write atomically: temp file then rename }
  Tmp := FPath + '.pztmp';
  try
    F := TFileStream.Create(Tmp, fmCreate);
    try
      if S <> '' then
        F.WriteBuffer(S[1], Length(S));
    finally
      F.Free;
    end;
    Result := RenameFile(Tmp, FPath);
    if not Result then
    begin
      DeleteFile(FPath);
      Result := RenameFile(Tmp, FPath);
    end;
  except
    Result := False;
  end;
  if Result then
    FDirty := False;
end;

function TPzIni.Find(const ASection: string; ACreate: Boolean): TPzIniSection;
var
  i: Integer;
begin
  for i := 0 to FSections.Count - 1 do
    if TPzIniSection(FSections[i]).Name = ASection then
      Exit(TPzIniSection(FSections[i]));
  Result := nil;
  if ACreate then
  begin
    Result := TPzIniSection.Create(ASection);
    FSections.Add(Result);
  end;
end;

function TPzIni.ReadValue(const ASection, AKey: string; const ADefault: string): string;
var
  Sec: TPzIniSection;
  i: Integer;
begin
  Result := ADefault;
  Sec := Find(ASection);
  if Sec = nil then
    Exit;
  i := Sec.Lines.IndexOfName(AKey);
  if i >= 0 then
    Result := Sec.Lines.ValueFromIndex[i];
end;

procedure TPzIni.WriteValue(const ASection, AKey, AValue: string);
var
  Sec: TPzIniSection;
  i: Integer;
begin
  if AValue = '' then
  begin
    DeleteKey(ASection, AKey);
    Exit;
  end;
  Sec := Find(ASection, True);
  i := Sec.Lines.IndexOfName(AKey);
  if i >= 0 then
  begin
    if Sec.Lines.ValueFromIndex[i] = AValue then
      Exit;
    Sec.Lines[i] := AKey + '=' + AValue;
  end
  else
    Sec.Lines.Add(AKey + '=' + AValue);
  FDirty := True;
end;

procedure TPzIni.DeleteKey(const ASection, AKey: string);
var
  Sec: TPzIniSection;
  i: Integer;
begin
  Sec := Find(ASection);
  if Sec = nil then
    Exit;
  i := Sec.Lines.IndexOfName(AKey);
  if i >= 0 then
  begin
    Sec.Lines.Delete(i);
    FDirty := True;
  end;
end;

{ chain helpers }

function ParseChain(const S: string): TPzChain;
var
  Parts, Args: TStringList;
  i, j, p: Integer;
  Item, Nm, A: string;
  F: TPzFilter;
begin
  Result := nil;
  Parts := TStringList.Create;
  Args := TStringList.Create;
  try
    Parts.StrictDelimiter := True;
    Parts.Delimiter := ';';
    Parts.DelimitedText := S;
    Args.StrictDelimiter := True;
    Args.Delimiter := ',';
    for i := 0 to Parts.Count - 1 do
    begin
      Item := Trim(Parts[i]);
      if Item = '' then
        Continue;
      p := Pos('=', Item);
      if p > 0 then
      begin
        Nm := Copy(Item, 1, p - 1);
        A := Copy(Item, p + 1, MaxInt);
      end
      else
      begin
        Nm := Item;
        A := '1';
      end;
      Args.DelimitedText := A;
      F.Name := Nm;
      SetLength(F.Args, 0);
      { first value is the enable flag ("1") }
      for j := 1 to Args.Count - 1 do
      begin
        SetLength(F.Args, Length(F.Args) + 1);
        F.Args[High(F.Args)] := Args[j];
      end;
      SetLength(Result, Length(Result) + 1);
      Result[High(Result)] := F;
    end;
  finally
    Parts.Free;
    Args.Free;
  end;
end;

function ChainToString(const C: TPzChain): string;
var
  i, j: Integer;
begin
  Result := '';
  for i := 0 to High(C) do
  begin
    Result := Result + C[i].Name + '=1';
    for j := 0 to High(C[i].Args) do
      Result := Result + ',' + C[i].Args[j];
    Result := Result + ';';
  end;
end;

function MakeFilter(const AName: string; const AArgs: array of string): TPzFilter;
var
  i: Integer;
begin
  Result.Name := AName;
  SetLength(Result.Args, Length(AArgs));
  for i := 0 to High(AArgs) do
    Result.Args[i] := AArgs[i];
end;

function FArg(const F: TPzFilter; i: Integer; ADefault: Double): Double;
begin
  if (i < 0) or (i > High(F.Args)) then
    Exit(ADefault);
  Result := StrToFloatDef(F.Args[i], ADefault, FS);
end;

function FmtF(v: Double): string;
begin
  Result := FormatFloat('0.000000', v, FS);
end;

procedure ChainAppend(var C: TPzChain; const F: TPzFilter);
begin
  SetLength(C, Length(C) + 1);
  C[High(C)] := F;
end;

function ChainPop(var C: TPzChain): TPzFilter;
begin
  Result := C[High(C)];
  SetLength(C, Length(C) - 1);
end;

function ParseRotate(const S: string): Integer;
var
  p, q: Integer;
begin
  Result := 0;
  p := Pos('(', S);
  q := Pos(')', S);
  if (p > 0) and (q > p) then
    Result := StrToIntDef(Copy(S, p + 1, q - p - 1), 0) mod 4;
end;

function RotateToString(q: Integer): string;
begin
  q := ((q mod 4) + 4) mod 4;
  if q = 0 then
    Result := ''
  else
    Result := 'rotate(' + IntToStr(q) + ')';
end;

function Crop64Decode(const Hex: string; out L, T, R, B: Double): Boolean;
var
  H: string;
  v: QWord;
begin
  H := Trim(Hex);
  L := 0;
  T := 0;
  R := 1;
  B := 1;
  Result := (H <> '') and (Length(H) <= 16);
  if not Result then
    Exit;
  while Length(H) < 16 do
    H := '0' + H;
  try
    v := StrToQWord('$' + H);
  except
    Exit(False);
  end;
  L := ((v shr 48) and $FFFF) / 65535;
  T := ((v shr 32) and $FFFF) / 65535;
  R := ((v shr 16) and $FFFF) / 65535;
  B := (v and $FFFF) / 65535;
  Result := (R > L) and (B > T);
end;

function Crop64Encode(L, T, R, B: Double): string;

  function W(x: Double): QWord;
  begin
    if x < 0 then x := 0;
    if x > 1 then x := 1;
    Result := Round(x * 65535);
  end;

var
  v: QWord;
begin
  v := (W(L) shl 48) or (W(T) shl 32) or (W(R) shl 16) or W(B);
  Result := LowerCase(IntToHex(v, 16));
  { Picasa strips leading zeros }
  while (Length(Result) > 1) and (Result[1] = '0') do
    Delete(Result, 1, 1);
end;

initialization
  FS := DefaultFormatSettings;
  FS.DecimalSeparator := '.';
  FS.ThousandSeparator := #0;

end.
