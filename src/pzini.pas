{ .picasa.ini reader/writer and the Picasa filter-chain model.

  Pizzicato never modifies image files. Edits live in the per-folder
  .picasa.ini exactly where Picasa keeps them, so edits made in Picasa show
  up here and vice versa. Unknown sections and keys are preserved verbatim.

  Another program (Picasa) may rewrite the file while it is loaded here, so
  the changes made here are logged as key-level operations: when the file
  on disk is newer than the copy in memory, it is read again and only those
  operations are replayed onto it before saving. }
unit pzini;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, BaseUnix;

const
  PZ_PICASA_INI = '.picasa.ini';
  { a folder without a .picasa.ini keeps Pizzicato's edits here, in the same
    format: Pizzicato never creates Picasa's file }
  PZ_PIZZI_INI = '.pizzi.ini';

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

  { what the file on disk was when it was read or written here }
  TPzFileStamp = record
    Exists: Boolean;
    Size, MTime, MNsec, Ino: Int64;
  end;

  { a change made here: Value set (or the key deleted) }
  TPzIniOp = record
    Section, Key, Value: string;
    Del: Boolean;
  end;

  { TPzIni }

  TPzIni = class
  private
    FPath: string;
    FSections: TList;
    FCRLF: Boolean;
    FDirty: Boolean;
    FStamp: TPzFileStamp;
    FOps: array of TPzIniOp;   // the changes not saved yet, oldest first
    FReloaded: Boolean;
    function GetCount: Integer;
    function GetSection(i: Integer): TPzIniSection;
    procedure Clear;
    procedure Read;
    procedure LogOp(const ASection, AKey, AValue: string; ADel: Boolean);
    procedure SetValue(const ASection, AKey, AValue: string);
    procedure RemoveKey(const ASection, AKey: string);
  public
    constructor Create(const APath: string);
    destructor Destroy; override;
    procedure Load;
    { the file was written by someone else since it was read here: read it
      again and replay the changes not saved yet; True if it was }
    function Refresh: Boolean;
    function ChangedOnDisk: Boolean;
    { writes the changes, on top of the newest file on disk }
    function Save: Boolean;
    { take the keys of Src this file lacks, then Src's unsaved changes }
    procedure MergeFrom(Src: TPzIni);
    function Find(const ASection: string; ACreate: Boolean = False): TPzIniSection;
    function ReadValue(const ASection, AKey: string;
      const ADefault: string = ''): string;
    function HasKey(const ASection, AKey: string): Boolean;
    procedure WriteValue(const ASection, AKey, AValue: string);
    procedure DeleteKey(const ASection, AKey: string);
    property Path: string read FPath;
    property Dirty: Boolean read FDirty write FDirty;
    { set when Refresh or Save read the file again (cleared by the caller) }
    property Reloaded: Boolean read FReloaded write FReloaded;
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
begin
  Clear;
  FSections.Free;
  inherited Destroy;
end;

procedure TPzIni.Clear;
var
  i: Integer;
begin
  for i := 0 to FSections.Count - 1 do
    TPzIniSection(FSections[i]).Free;
  FSections.Clear;
end;

function StampOf(const APath: string): TPzFileStamp;
var
  St: Stat;
begin
  FillChar(Result, SizeOf(Result), 0);
  if FpStat(APath, St) <> 0 then
    Exit;
  Result.Exists := True;
  Result.Size := St.st_size;
  Result.MTime := St.st_mtime;
  Result.MNsec := St.st_mtime_nsec;
  Result.Ino := St.st_ino;
end;

function SameStamp(const A, B: TPzFileStamp): Boolean;
begin
  Result := (A.Exists = B.Exists) and (A.Size = B.Size) and
    (A.MTime = B.MTime) and (A.MNsec = B.MNsec) and (A.Ino = B.Ino);
end;

function TPzIni.ChangedOnDisk: Boolean;
begin
  Result := not SameStamp(StampOf(FPath), FStamp);
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
begin
  FOps := nil;
  Read;
  FDirty := False;
end;

{ (re)read the file; the unsaved changes are kept in FOps }
procedure TPzIni.Read;
var
  SL: TStringList;
  i: Integer;
  L: string;
  Cur: TPzIniSection;
  Raw: string;
  F: TFileStream;
begin
  Clear;
  FStamp := StampOf(FPath);
  if not FStamp.Exists then
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
end;

function TPzIni.Refresh: Boolean;
var
  i: Integer;
begin
  Result := ChangedOnDisk;
  if not Result then
    Exit;
  Read;
  for i := 0 to High(FOps) do
    if FOps[i].Del then
      RemoveKey(FOps[i].Section, FOps[i].Key)
    else
      SetValue(FOps[i].Section, FOps[i].Key, FOps[i].Value);
  FReloaded := True;
end;

procedure TPzIni.MergeFrom(Src: TPzIni);
var
  i, j: Integer;
  Sec: TPzIniSection;
  K: string;
begin
  for i := 0 to Src.Count - 1 do
  begin
    Sec := Src.Sections[i];
    if Find(Sec.Name) = nil then
    begin
      Find(Sec.Name, True); // keep empty sections too
      FDirty := True;
    end;
    for j := 0 to Sec.Lines.Count - 1 do
    begin
      K := Sec.Lines.Names[j];
      if (K <> '') and not HasKey(Sec.Name, K) then
        WriteValue(Sec.Name, K, Sec.Lines.ValueFromIndex[j]);
    end;
  end;
  for i := 0 to High(Src.FOps) do
    if Src.FOps[i].Del then
      DeleteKey(Src.FOps[i].Section, Src.FOps[i].Key)
    else
      WriteValue(Src.FOps[i].Section, Src.FOps[i].Key, Src.FOps[i].Value);
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
  { someone else wrote the file since: start from theirs }
  Refresh;
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
    { written meanwhile (a very narrow window): merge again }
    if ChangedOnDisk then
    begin
      DeleteFile(Tmp);
      Result := Save;
      Exit;
    end;
    Result := RenameFile(Tmp, FPath);
  except
    Result := False;
  end;
  if Result then
  begin
    FDirty := False;
    FOps := nil;
    FStamp := StampOf(FPath);
  end;
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

function TPzIni.HasKey(const ASection, AKey: string): Boolean;
var
  Sec: TPzIniSection;
begin
  Sec := Find(ASection);
  Result := (Sec <> nil) and (Sec.Lines.IndexOfName(AKey) >= 0);
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

procedure TPzIni.LogOp(const ASection, AKey, AValue: string; ADel: Boolean);
var
  i, n: Integer;
begin
  { one entry per key: the latest change }
  n := Length(FOps);
  for i := 0 to n - 1 do
    if (FOps[i].Section = ASection) and SameText(FOps[i].Key, AKey) then
    begin
      FOps[i].Value := AValue;
      FOps[i].Del := ADel;
      Exit;
    end;
  SetLength(FOps, n + 1);
  FOps[n].Section := ASection;
  FOps[n].Key := AKey;
  FOps[n].Value := AValue;
  FOps[n].Del := ADel;
end;

procedure TPzIni.SetValue(const ASection, AKey, AValue: string);
var
  Sec: TPzIniSection;
  i: Integer;
begin
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

procedure TPzIni.RemoveKey(const ASection, AKey: string);
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

{ only real changes are logged: writing the value the file has is no
  change, so a newer value written there by someone else is kept }
procedure TPzIni.WriteValue(const ASection, AKey, AValue: string);
begin
  if AValue = '' then
  begin
    DeleteKey(ASection, AKey);
    Exit;
  end;
  if HasKey(ASection, AKey) and (ReadValue(ASection, AKey) = AValue) then
    Exit;
  LogOp(ASection, AKey, AValue, False);
  SetValue(ASection, AKey, AValue);
end;

procedure TPzIni.DeleteKey(const ASection, AKey: string);
begin
  if not HasKey(ASection, AKey) then
    Exit;
  LogOp(ASection, AKey, '', True);
  RemoveKey(ASection, AKey);
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
