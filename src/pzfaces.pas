{ People, as in Picasa: a background indexer finds faces (YuNet) in every
  photo, embeds them (SFace) and groups similar faces as it goes; naming a
  group makes it a person. Faces, groups and people live in the thumbnail
  DB (tables faces, facescan, persons); named faces are also written to
  .picasa.ini in Picasa's own form by the main form. }
unit pzfaces;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, SyncObjs, ctypes, sqlite3, pzcorebind, pzai;

const
  FACE_DIM = 128;
  { a face joins a group when this close to the group's mean (cosine);
    SFace's same-person threshold is 0.363 }
  FACE_JOIN = 0.42;
  FACE_MIN_PX = 40;    // smaller faces are kept but not recognised
  FACE_DECODE = 1600;  // photos are scanned at this long edge

type
  Tpz_face = record
    x, y, w, h, score: cfloat;
    lm: array[0..9] of cfloat;
  end;
  Ppz_face = ^Tpz_face;

  TPzPeopleKind = (pkPerson, pkGroup);

  TPzPeopleItem = class
  public
    Kind: TPzPeopleKind;
    Id: Int64;           // person id or group id
    Name: string;
    Photos: Integer;
  end;

  TPzFaceRect = record
    FaceId, Photo: Int64;
    X, Y, W, H: Double;  // normalised to the upright photo
  end;
  TPzFaceRects = array of TPzFaceRect;

  TPzFaceIndex = class(TThread)
  private
    FDBPath: string;
    FMain: psqlite3;     // the main thread's own connection
    FWake: TEvent;
    FDone, FTotal, FFaces: Integer;
    FError: string;
    FChanged: Boolean;
    FAuto: Boolean;          // scan every new photo; else only on request
    FWork: TPzWorkList;
    FJobDone, FJobTotal: Integer;
  protected
    procedure Execute; override;
  public
    constructor Create(const ADBPath: string; AAuto: Boolean = True);
    destructor Destroy; override;
    procedure Stop;
    procedure Kick;
    { manual mode: find the faces in these photos (those not scanned yet) }
    procedure Request(Id: Int64);
    procedure RequestAll;
    procedure Cancel;
    { main thread: people (named) first, then unnamed groups of at least
      MinGroup photos, biggest first }
    function People(MinGroup, MaxGroups: Integer): TList;
    function PhotoIds(Item: TPzPeopleItem): TList; // of Int64 cast to Pointer
    function GroupFaces(GroupId: Int64): TPzFaceRects;
    function PersonFaces(PersonId: Int64): TPzFaceRects;
    { name a group (an existing name joins that person); returns the person }
    function NameGroup(GroupId: Int64; const AName: string; out Hash: string): Int64;
    function RenamePerson(PersonId: Int64; const AName: string): Boolean;
    function PersonHash(PersonId: Int64): string;
    { photo id -> 'Name1, Name2', for the search box }
    function PhotoNames: TStringList;
    property Done: Integer read FDone;
    property Total: Integer read FTotal;
    property Faces: Integer read FFaces;
    property Error: string read FError;
    property Changed: Boolean read FChanged write FChanged;
    property Auto: Boolean read FAuto;
    { the photos of the run in progress (manual mode) }
    property JobDone: Integer read FJobDone;
    property JobTotal: Integer read FJobTotal;
  end;

function PzFacesReady(out Why: string): Boolean;
{ Picasa's rect64(): left, top, right, bottom as 16-bit fractions, in hex }
function PicasaRect64(X, Y, W, H: Double): string;
function NewContactHash: string;

implementation

uses
  Math;

function pz_ai_faces(det: Ppz_ai; img: Ppz_image; size: cint;
  thresh: cfloat; faces: Ppz_face; max: cint): cint; cdecl; external;
function pz_ai_face_embed(rec: Ppz_ai; img: Ppz_image; f: Ppz_face; emb: PSingle): cint;
  cdecl; external;

function FaceFile(const N: string): string;
begin
  Result := PzAIModelDir + '/' + N;
end;

function PzFacesReady(out Why: string): Boolean;
begin
  Why := '';
  if not PzAIAvailable then
    Why := 'This Pizzicato was built without AI support (make AI=1).'
  else if not FileExists(FaceFile('face_yunet.mnn')) or not
    FileExists(FaceFile('face_sface.mnn')) then
    Why := 'The face models are not installed in ' + PzAIModelDir +
      '. Download them with AI Models... (top bar).';
  Result := Why = '';
end;

function PicasaRect64(X, Y, W, H: Double): string;

  function C(v: Double): string;
  begin
    Result := IntToHex(EnsureRange(Round(v * 65535), 0, 65535), 4);
  end;

begin
  Result := LowerCase(C(X) + C(Y) + C(X + W) + C(Y + H));
end;

function NewContactHash: string;
var
  i: Integer;
begin
  Result := '';
  for i := 1 to 16 do
    Result := Result + LowerCase(IntToHex(Random(16), 1));
end;

procedure Exec(DB: psqlite3; const S: string);
begin
  sqlite3_exec(DB, PAnsiChar(S), nil, nil, nil);
end;

procedure MakeTables(DB: psqlite3);
begin
  Exec(DB, 'CREATE TABLE IF NOT EXISTS faces(id INTEGER PRIMARY KEY, photo INTEGER, ' +
    'x REAL, y REAL, w REAL, h REAL, score REAL, emb BLOB, grp INTEGER, person INTEGER DEFAULT 0)');
  Exec(DB, 'CREATE INDEX IF NOT EXISTS faces_photo ON faces(photo)');
  Exec(DB, 'CREATE INDEX IF NOT EXISTS faces_grp ON faces(grp)');
  Exec(DB, 'CREATE TABLE IF NOT EXISTS facescan(photo INTEGER PRIMARY KEY, n INTEGER)');
  Exec(DB, 'CREATE TABLE IF NOT EXISTS persons(id INTEGER PRIMARY KEY, name TEXT UNIQUE, hash TEXT)');
end;

{ TPzFaceIndex }

constructor TPzFaceIndex.Create(const ADBPath: string; AAuto: Boolean);
begin
  FDBPath := ADBPath;
  FAuto := AAuto;
  FWork := TPzWorkList.Create;
  FWake := TEvent.Create(nil, False, False, '');
  if sqlite3_open_v2(PAnsiChar(ADBPath), @FMain, SQLITE_OPEN_READWRITE, nil) =
    SQLITE_OK then
  begin
    sqlite3_busy_timeout(FMain, 10000);
    MakeTables(FMain);
  end;
  FreeOnTerminate := False;
  inherited Create(False);
  Priority := tpLower;
end;

destructor TPzFaceIndex.Destroy;
begin
  Stop;
  if FMain <> nil then
    sqlite3_close(FMain);
  FWake.Free;
  FWork.Free;
  inherited Destroy;
end;

procedure TPzFaceIndex.Stop;
begin
  if Finished then
    Exit;
  Terminate;
  FWake.SetEvent;
  WaitFor;
end;

procedure TPzFaceIndex.Kick;
begin
  FWake.SetEvent;
end;

procedure TPzFaceIndex.Request(Id: Int64);
begin
  FWork.Add(Id);
  FWake.SetEvent;
end;

procedure TPzFaceIndex.RequestAll;
begin
  FWork.AddAll;
  FWake.SetEvent;
end;

procedure TPzFaceIndex.Cancel;
begin
  FWork.Cancel;
end;

function TPzFaceIndex.People(MinGroup, MaxGroups: Integer): TList;
var
  St: psqlite3_stmt;
  It: TPzPeopleItem;
begin
  Result := TList.Create;
  if FMain = nil then
    Exit;
  if sqlite3_prepare_v2(FMain,
    'SELECT p.id, p.name, COUNT(DISTINCT f.photo) FROM persons p ' +
    'JOIN faces f ON f.person = p.id GROUP BY p.id ORDER BY p.name COLLATE NOCASE',
    -1, @St, nil) = SQLITE_OK then
  begin
    while sqlite3_step(St) = SQLITE_ROW do
    begin
      It := TPzPeopleItem.Create;
      It.Kind := pkPerson;
      It.Id := sqlite3_column_int64(St, 0);
      It.Name := StrPas(sqlite3_column_text(St, 1));
      It.Photos := sqlite3_column_int(St, 2);
      Result.Add(It);
    end;
    sqlite3_finalize(St);
  end;
  if sqlite3_prepare_v2(FMain,
    PAnsiChar('SELECT grp, COUNT(DISTINCT photo) AS n FROM faces ' +
    'WHERE person = 0 AND grp > 0 GROUP BY grp HAVING n >= ' +
    IntToStr(MinGroup) + ' ORDER BY n DESC LIMIT ' + IntToStr(MaxGroups)), -1,
    @St, nil) = SQLITE_OK then
  begin
    while sqlite3_step(St) = SQLITE_ROW do
    begin
      It := TPzPeopleItem.Create;
      It.Kind := pkGroup;
      It.Id := sqlite3_column_int64(St, 0);
      It.Photos := sqlite3_column_int(St, 1);
      It.Name := Format('Unnamed %d', [Result.Count + 1]);
      Result.Add(It);
    end;
    sqlite3_finalize(St);
  end;
end;

function TPzFaceIndex.PhotoIds(Item: TPzPeopleItem): TList;
var
  St: psqlite3_stmt;
  Q: string;
begin
  Result := TList.Create;
  if FMain = nil then
    Exit;
  if Item.Kind = pkPerson then
    Q := 'SELECT DISTINCT photo FROM faces WHERE person = ' + IntToStr(Item.Id)
  else
    Q := 'SELECT DISTINCT photo FROM faces WHERE person = 0 AND grp = ' +
      IntToStr(Item.Id);
  if sqlite3_prepare_v2(FMain, PAnsiChar(Q), -1, @St, nil) = SQLITE_OK then
  begin
    while sqlite3_step(St) = SQLITE_ROW do
      Result.Add(Pointer(PtrInt(sqlite3_column_int64(St, 0))));
    sqlite3_finalize(St);
  end;
end;

function QueryRects(DB: psqlite3; const Q: string): TPzFaceRects;
var
  St: psqlite3_stmt;
  n: Integer;
begin
  Result := nil;
  n := 0;
  if sqlite3_prepare_v2(DB, PAnsiChar(Q), -1, @St, nil) = SQLITE_OK then
  begin
    while sqlite3_step(St) = SQLITE_ROW do
    begin
      SetLength(Result, n + 1);
      Result[n].FaceId := sqlite3_column_int64(St, 0);
      Result[n].Photo := sqlite3_column_int64(St, 1);
      Result[n].X := sqlite3_column_double(St, 2);
      Result[n].Y := sqlite3_column_double(St, 3);
      Result[n].W := sqlite3_column_double(St, 4);
      Result[n].H := sqlite3_column_double(St, 5);
      Inc(n);
    end;
    sqlite3_finalize(St);
  end;
end;

function TPzFaceIndex.GroupFaces(GroupId: Int64): TPzFaceRects;
begin
  Result := QueryRects(FMain, 'SELECT id, photo, x, y, w, h FROM faces WHERE grp = ' +
    IntToStr(GroupId));
end;

function TPzFaceIndex.PersonFaces(PersonId: Int64): TPzFaceRects;
begin
  Result := QueryRects(FMain, 'SELECT id, photo, x, y, w, h FROM faces WHERE person = ' +
    IntToStr(PersonId));
end;

function TPzFaceIndex.NameGroup(GroupId: Int64; const AName: string;
  out Hash: string): Int64;
var
  St: psqlite3_stmt;
begin
  Result := 0;
  Hash := '';
  if (FMain = nil) or (Trim(AName) = '') then
    Exit;
  if sqlite3_prepare_v2(FMain, 'SELECT id, hash FROM persons WHERE name = ?',
    -1, @St, nil) = SQLITE_OK then
  begin
    sqlite3_bind_text(St, 1, PAnsiChar(AName), -1, nil);
    if sqlite3_step(St) = SQLITE_ROW then
    begin
      Result := sqlite3_column_int64(St, 0);
      Hash := StrPas(sqlite3_column_text(St, 1));
    end;
    sqlite3_finalize(St);
  end;
  if Result = 0 then
  begin
    Hash := NewContactHash;
    if sqlite3_prepare_v2(FMain, 'INSERT INTO persons(name, hash) VALUES(?, ?)',
      -1, @St, nil) = SQLITE_OK then
    begin
      sqlite3_bind_text(St, 1, PAnsiChar(AName), -1, nil);
      sqlite3_bind_text(St, 2, PAnsiChar(Hash), -1, nil);
      sqlite3_step(St);
      sqlite3_finalize(St);
      Result := sqlite3_last_insert_rowid(FMain);
    end;
  end;
  if Result > 0 then
    Exec(FMain, Format('UPDATE faces SET person = %d WHERE grp = %d',
      [Result, GroupId]));
end;

function TPzFaceIndex.RenamePerson(PersonId: Int64; const AName: string): Boolean;
var
  St: psqlite3_stmt;
begin
  Result := False;
  if (FMain = nil) or (Trim(AName) = '') then
    Exit;
  if sqlite3_prepare_v2(FMain, 'UPDATE persons SET name = ? WHERE id = ?', -1,
    @St, nil) = SQLITE_OK then
  begin
    sqlite3_bind_text(St, 1, PAnsiChar(AName), -1, nil);
    sqlite3_bind_int64(St, 2, PersonId);
    Result := sqlite3_step(St) = SQLITE_DONE;
    sqlite3_finalize(St);
  end;
end;

function TPzFaceIndex.PersonHash(PersonId: Int64): string;
var
  St: psqlite3_stmt;
begin
  Result := '';
  if (FMain <> nil) and (sqlite3_prepare_v2(FMain,
    PAnsiChar('SELECT hash FROM persons WHERE id = ' + IntToStr(PersonId)),
    -1, @St, nil) = SQLITE_OK) then
  begin
    if sqlite3_step(St) = SQLITE_ROW then
      Result := StrPas(sqlite3_column_text(St, 0));
    sqlite3_finalize(St);
  end;
end;

function TPzFaceIndex.PhotoNames: TStringList;
var
  St: psqlite3_stmt;
  k: Integer;
  Id: string;
begin
  Result := TStringList.Create;
  Result.Sorted := True;
  if FMain = nil then
    Exit;
  if sqlite3_prepare_v2(FMain, 'SELECT DISTINCT f.photo, p.name FROM faces f ' +
    'JOIN persons p ON p.id = f.person', -1, @St, nil) = SQLITE_OK then
  begin
    while sqlite3_step(St) = SQLITE_ROW do
    begin
      Id := IntToStr(sqlite3_column_int64(St, 0));
      k := Result.IndexOfName(Id);
      if k < 0 then
        Result.Add(Id + '=' + StrPas(sqlite3_column_text(St, 1)))
      else
        Result.ValueFromIndex[k] :=
          Result.ValueFromIndex[k] + ', ' + StrPas(sqlite3_column_text(St, 1));
    end;
    sqlite3_finalize(St);
  end;
end;

procedure TPzFaceIndex.Execute;
type
  TCentroid = record
    Sum: array[0..FACE_DIM - 1] of Double;
    N: Integer;
  end;
var
  DB: psqlite3;
  St, Ins, Scan: psqlite3_stmt;
  Det, Rec: Ppz_ai;
  Ids: array of Int64;
  Paths: TStringList;
  Grp: array of TCentroid;   // index = group id
  Img: Tpz_image;
  M: Tpz_meta;
  F: array[0..63] of Tpz_face;
  E: array[0..FACE_DIM - 1] of Single;
  i, j, k, n, nf, g, best, Batch: Integer;
  c, bc, nrm: Double;
  P: PByte;
  Want: TPzBoolArray;
  All: Boolean;
  Id: Int64;

  function Stopped: Boolean;
  begin
    Result := Terminated or (not FAuto and FWork.Cancelled);
  end;

begin
  DB := nil;
  Det := nil;
  Rec := nil;
  Paths := TStringList.Create;
  try
    if sqlite3_open_v2(PAnsiChar(FDBPath), @DB, SQLITE_OPEN_READWRITE, nil) <>
      SQLITE_OK then
    begin
      FError := 'cannot open ' + FDBPath;
      Exit;
    end;
    sqlite3_busy_timeout(DB, 10000);
    MakeTables(DB);
    { the groups so far, from their faces }
    if sqlite3_prepare_v2(DB,
      'SELECT grp, emb FROM faces WHERE grp > 0 AND emb IS NOT NULL', -1, @St, nil) =
      SQLITE_OK then
    begin
      while not Terminated and (sqlite3_step(St) = SQLITE_ROW) do
      begin
        g := sqlite3_column_int(St, 0);
        if sqlite3_column_bytes(St, 1) <> FACE_DIM * 4 then
          Continue;
        if g >= Length(Grp) then
          SetLength(Grp, g + 1024);
        P := sqlite3_column_blob(St, 1);
        for k := 0 to FACE_DIM - 1 do
          Grp[g].Sum[k] := Grp[g].Sum[k] + PSingle(P + 4 * k)^;
        Inc(Grp[g].N);
        Inc(FFaces);
      end;
      sqlite3_finalize(St);
    end;
    n := 0;
    for g := 1 to High(Grp) do
      if Grp[g].N > 0 then
        n := g;
    SetLength(Grp, n + 1);
    sqlite3_prepare_v2(DB, 'INSERT INTO faces(photo, x, y, w, h, score, emb, grp) ' +
      'VALUES(?, ?, ?, ?, ?, ?, ?, ?)', -1, @Ins, nil);
    sqlite3_prepare_v2(DB, 'INSERT OR REPLACE INTO facescan(photo, n) VALUES(?, ?)',
      -1, @Scan, nil);
    while not Terminated do
    begin
      { manual mode: nothing to do until asked }
      All := True;
      Want := nil;
      if not FAuto and not FWork.Take(Want, All) then
      begin
        FWake.WaitFor(INFINITE);
        Continue;
      end;
      { the models go on the GPU only once there is work }
      if Det = nil then
        if (pz_ai_open(PAnsiChar(FaceFile('face_yunet.mnn')), PZ_AI_OPENCL,
          -1, 0, @Det) <> 0) or
          (pz_ai_open(PAnsiChar(FaceFile('face_sface.mnn')), PZ_AI_OPENCL, -1,
          0, @Rec) <> 0) then
        begin
          FError := StrPas(pz_ai_error);
          Break;
        end;
      { the photos not scanned yet (of those asked for), newest first }
      Ids := nil;
      Paths.Clear;
      n := 0;
      if sqlite3_prepare_v2(DB, 'SELECT p.id, f.path || ''/'' || p.name FROM photos p ' +
        'JOIN folders f ON f.id = p.folder WHERE p.id NOT IN (SELECT photo FROM facescan) '
        + 'ORDER BY p.id DESC', -1, @St, nil) = SQLITE_OK then
      begin
        while sqlite3_step(St) = SQLITE_ROW do
        begin
          Id := sqlite3_column_int64(St, 0);
          if not All and ((Id >= Length(Want)) or not Want[Id]) then
            Continue;
          if n >= Length(Ids) then
            SetLength(Ids, Max(1024, n * 2));
          Ids[n] := Id;
          Paths.Add(StrPas(sqlite3_column_text(St, 1)));
          Inc(n);
        end;
        sqlite3_finalize(St);
      end;
      if sqlite3_prepare_v2(DB,
        'SELECT (SELECT COUNT(*) FROM photos), (SELECT COUNT(*) FROM facescan)',
        -1, @St, nil) = SQLITE_OK then
      begin
        if sqlite3_step(St) = SQLITE_ROW then
        begin
          FTotal := sqlite3_column_int(St, 0);
          FDone := sqlite3_column_int(St, 1);
        end;
        sqlite3_finalize(St);
      end;
      FJobTotal := n;
      FJobDone := 0;
      i := 0;
      while (i < n) and not Stopped do
      begin
        Batch := 0;
        while (i < n) and (Batch < 16) and not Stopped do
        begin
          PzInit(Img);
          nf := 0;
          if pz_load(PAnsiChar(Paths[i]), FACE_DECODE, FACE_DECODE,
            0, @Img, @M) >= 0 then
          begin
            nf := pz_ai_faces(Det, @Img, 960, 0.75, @F[0], Length(F));
            { one short write transaction per photo, after the slow decode
              and detection, so the other writers are not kept waiting }
            sqlite3_exec(DB, 'BEGIN IMMEDIATE', nil, nil, nil);
            for j := 0 to nf - 1 do
            begin
              g := 0;
              if (F[j].w >= FACE_MIN_PX) and
                (pz_ai_face_embed(Rec, @Img, @F[j], @E[0]) = 0) then
              begin
                { the nearest group, or a new one }
                best := 0;
                bc := FACE_JOIN;
                for g := 1 to High(Grp) do
                  if Grp[g].N > 0 then
                  begin
                    c := 0;
                    nrm := 0;
                    for k := 0 to FACE_DIM - 1 do
                    begin
                      c := c + Grp[g].Sum[k] * E[k];
                      nrm := nrm + Sqr(Grp[g].Sum[k]);
                    end;
                    if nrm > 0 then
                      c := c / Sqrt(nrm);
                    if c >= bc then
                    begin
                      bc := c;
                      best := g;
                    end;
                  end;
                g := best;
                if g = 0 then
                begin
                  g := Length(Grp);
                  SetLength(Grp, g + 1);
                  FillChar(Grp[g], SizeOf(Grp[g]), 0);
                end;
                for k := 0 to FACE_DIM - 1 do
                  Grp[g].Sum[k] := Grp[g].Sum[k] + E[k];
                Inc(Grp[g].N);
              end;
              sqlite3_reset(Ins);
              sqlite3_bind_int64(Ins, 1, Ids[i]);
              sqlite3_bind_double(Ins, 2, F[j].x / Img.w);
              sqlite3_bind_double(Ins, 3, F[j].y / Img.h);
              sqlite3_bind_double(Ins, 4, F[j].w / Img.w);
              sqlite3_bind_double(Ins, 5, F[j].h / Img.h);
              sqlite3_bind_double(Ins, 6, F[j].score);
              if g > 0 then
              begin
                sqlite3_bind_blob(Ins, 7, @E[0], FACE_DIM * 4, nil);
                sqlite3_bind_int(Ins, 8, g);
              end
              else
              begin
                sqlite3_bind_null(Ins, 7);
                sqlite3_bind_int(Ins, 8, 0);
              end;
              sqlite3_step(Ins);
              Inc(FFaces);
            end;
            pz_free(@Img);
          end
          else
            sqlite3_exec(DB, 'BEGIN IMMEDIATE', nil, nil, nil);
          sqlite3_reset(Scan);
          sqlite3_bind_int64(Scan, 1, Ids[i]);
          sqlite3_bind_int(Scan, 2, Max(0, nf));
          sqlite3_step(Scan);
          sqlite3_exec(DB, 'COMMIT', nil, nil, nil);
          Inc(i);
          Inc(Batch);
          Inc(FDone);
          Inc(FJobDone);
        end;
        FChanged := True;
      end;
      FJobTotal := 0;
      FJobDone := 0;
      if FAuto and not Terminated then
        FWake.WaitFor(60000);
    end;
    sqlite3_finalize(Ins);
    sqlite3_finalize(Scan);
  finally
    Paths.Free;
    if Det <> nil then
      pz_ai_close(Det);
    if Rec <> nil then
      pz_ai_close(Rec);
    if DB <> nil then
      sqlite3_close(DB);
  end;
end;

end.
