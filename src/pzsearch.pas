{ Search by description (CLIP): a background indexer embeds every photo's
  cached thumbnail into the DB's clip table and keeps all embeddings in
  memory as int8 vectors; a query is embedded by CLIP's text tower (on the
  CPU, a few ms) and scored against all of them at once. The same
  embeddings give the Properties panel its zero-shot "Scene" labels. }
unit pzsearch;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, SyncObjs, ctypes, sqlite3, pzcorebind, pzai;

const
  CLIP_DIM = 512;

type
  TPzHit = record
    Id: Int64;
    Score: Single;
  end;
  TPzHits = array of TPzHit;

  { the indexer thread, which also owns the in-memory index }
  TPzClipIndex = class(TThread)
  private
    FDBPath: string;
    FLock: TCriticalSection;
    FWake: TEvent;
    FIds: array of Int64;
    FVec: array of ShortInt;   // Count x CLIP_DIM
    FScale: array of Single;
    FCount: Integer;
    FRow: array of Integer;    // photo id -> row, -1 = none
    FLabels: array of Single;  // label embeddings, labels x CLIP_DIM
    FLabelsReady: Boolean;
    FTotal: Integer;           // thumbnails in the DB
    FError: string;
    FAdded: Integer;           // rows added since the last ClearAdded
    procedure Add(Id: Int64; const E: array of Single; Blob: PByte);
  protected
    procedure Execute; override;
  public
    constructor Create(const ADBPath: string);
    destructor Destroy; override;
    procedure Stop;
    procedure Kick;            // look for new thumbnails now
    { the best matches of a query embedding, best first }
    function Search(const Q: array of Single; MaxHits: Integer): TPzHits;
    { the photo's top scene labels with their probabilities }
    function SceneLabels(Id: Int64; N: Integer;
      out Probs: array of Single): TStringArray;
    function Indexed: Integer;
    property Total: Integer read FTotal;
    property LabelsReady: Boolean read FLabelsReady;
    property Error: string read FError;
    property Added: Integer read FAdded write FAdded;
  end;

  { CLIP's text tower in the calling (main) thread }
  TPzClipText = class
  private
    FH: Ppz_ai;
    FError: string;
  public
    destructor Destroy; override;
    function Embed(const Text: string; out E: array of Single): Boolean;
    property Error: string read FError;
  end;

function PzSceneLabelCount: Integer;

{ the CLIP files are installed (and AI is built in); Why says what is missing }
function PzClipReady(out Why: string): Boolean;

implementation

uses
  Math;

{$I pzlabels.inc}

function PzSceneLabelCount: Integer;
begin
  Result := Length(PZ_SCENE_LABELS);
end;

function pz_ai_dim(h: Ppz_ai): cint; cdecl; external;
function pz_ai_clip_image(h: Ppz_ai; img: Ppz_image; emb: PSingle): cint;
  cdecl; external;
function pz_ai_clip_load_bpe(h: Ppz_ai; vocab, merges: PAnsiChar): cint; cdecl; external;
function pz_ai_clip_text(h: Ppz_ai; text: PAnsiChar; emb: PSingle): cint;
  cdecl; external;

function ClipFile(const N: string): string;
begin
  Result := PzAIModelDir + '/' + N;
end;

function PzClipReady(out Why: string): Boolean;
const
  F: array[0..3] of string = ('clip_vision.mnn', 'clip_text.mnn', 'clip_vocab.json',
    'clip_merges.txt');
var
  i: Integer;
begin
  Why := '';
  if not PzAIAvailable then
    Why := 'This Pizzicato was built without AI support (make AI=1).'
  else
    for i := 0 to High(F) do
      if not FileExists(ClipFile(F[i])) then
      begin
        Why := Format('The search model %s is not installed in %s.' +
          LineEnding + 'Run tools/fetch_models.sh clip to download it.',
          [F[i], PzAIModelDir]);
        Break;
      end;
  Result := Why = '';
end;

function OpenText(out H: Ppz_ai; out Err: string): Boolean;
begin
  Err := '';
  H := nil;
  { the CPU: MNN's OpenCL returns one embedding for every query here }
  Result := (pz_ai_open(PAnsiChar(ClipFile('clip_text.mnn')), PZ_AI_CPU, -1, 4, @H) =
    0) and (pz_ai_clip_load_bpe(H, PAnsiChar(ClipFile('clip_vocab.json')),
    PAnsiChar(ClipFile('clip_merges.txt'))) = 0);
  if not Result then
  begin
    Err := StrPas(pz_ai_error);
    if H <> nil then
      pz_ai_close(H);
    H := nil;
  end;
end;

{ TPzClipText }

destructor TPzClipText.Destroy;
begin
  if FH <> nil then
    pz_ai_close(FH);
  inherited Destroy;
end;

function TPzClipText.Embed(const Text: string; out E: array of Single): Boolean;
var
  Why: string;
begin
  Result := False;
  if not PzClipReady(Why) then
  begin
    FError := Why;
    Exit;
  end;
  if (FH = nil) and not OpenText(FH, FError) then
    Exit;
  Result := pz_ai_clip_text(FH, PAnsiChar(Text), @E[0]) = 0;
  if not Result then
    FError := StrPas(pz_ai_error);
end;

{ TPzClipIndex }

constructor TPzClipIndex.Create(const ADBPath: string);
begin
  FDBPath := ADBPath;
  FLock := TCriticalSection.Create;
  FWake := TEvent.Create(nil, False, False, '');
  FreeOnTerminate := False;
  inherited Create(False);
  Priority := tpLower;
end;

destructor TPzClipIndex.Destroy;
begin
  Stop;
  FWake.Free;
  FLock.Free;
  inherited Destroy;
end;

procedure TPzClipIndex.Stop;
begin
  if Finished then
    Exit;
  Terminate;
  FWake.SetEvent;
  WaitFor;
end;

procedure TPzClipIndex.Kick;
begin
  FWake.SetEvent;
end;

function TPzClipIndex.Indexed: Integer;
begin
  Result := FCount;
end;

{ append one embedding (E as floats, or Blob as stored: scale + int8s) }
procedure TPzClipIndex.Add(Id: Int64; const E: array of Single; Blob: PByte);
var
  k, r: Integer;
  m, s: Single;
begin
  FLock.Enter;
  try
    if (Id >= Length(FRow)) then
    begin
      k := Length(FRow);
      SetLength(FRow, Max(Id + 1, k * 3 div 2 + 1024));
      for r := k to High(FRow) do
        FRow[r] := -1;
    end;
    r := FRow[Id];
    if r < 0 then
    begin
      if FCount >= Length(FIds) then
      begin
        k := Max(1024, FCount * 3 div 2);
        SetLength(FIds, k);
        SetLength(FScale, k);
        SetLength(FVec, k * CLIP_DIM);
      end;
      r := FCount;
      Inc(FCount);
      FRow[Id] := r;
      FIds[r] := Id;
    end;
    if Blob <> nil then
    begin
      Move(Blob^, FScale[r], 4);
      Move((Blob + 4)^, FVec[r * CLIP_DIM], CLIP_DIM);
    end
    else
    begin
      m := 0;
      for k := 0 to CLIP_DIM - 1 do
        m := Max(m, Abs(E[k]));
      if m = 0 then
        m := 1;
      s := m / 127;
      FScale[r] := s;
      for k := 0 to CLIP_DIM - 1 do
        FVec[r * CLIP_DIM + k] := EnsureRange(Round(E[k] / s), -127, 127);
    end;
  finally
    FLock.Leave;
  end;
end;

function TPzClipIndex.Search(const Q: array of Single; MaxHits: Integer): TPzHits;
var
  Sc: array of Single;
  Ord: array of Integer;
  i, n: Integer;

  procedure Sort(L, R: Integer); // descending by score
  var
    i, j, t: Integer;
    p: Single;
  begin
    repeat
      i := L;
      j := R;
      p := Sc[Ord[(L + R) shr 1]];
      repeat
        while Sc[Ord[i]] > p do Inc(i);
        while Sc[Ord[j]] < p do Dec(j);
        if i <= j then
        begin
          t := Ord[i];
          Ord[i] := Ord[j];
          Ord[j] := t;
          Inc(i);
          Dec(j);
        end;
      until i > j;
      if L < j then Sort(L, j);
      L := i;
    until i >= R;
  end;

begin
  Result := nil;
  FLock.Enter;
  try
    n := FCount;
    if n = 0 then
      Exit;
    SetLength(Sc, n);
    pz_dot_i8(@FVec[0], @FScale[0], n, CLIP_DIM, @Q[0], @Sc[0]);
    SetLength(Ord, n);
    for i := 0 to n - 1 do
      Ord[i] := i;
    Sort(0, n - 1);
    n := Min(n, MaxHits);
    SetLength(Result, n);
    for i := 0 to n - 1 do
    begin
      Result[i].Id := FIds[Ord[i]];
      Result[i].Score := Sc[Ord[i]];
    end;
  finally
    FLock.Leave;
  end;
end;

function TPzClipIndex.SceneLabels(Id: Int64; N: Integer;
  out Probs: array of Single): TStringArray;
var
  r, i, k, b: Integer;
  V: array[0..CLIP_DIM - 1] of Single;
  L: array of Single;
  mx, sum: Double;
  Used: array of Boolean;
begin
  Result := nil;
  if not FLabelsReady then
    Exit;
  FLock.Enter;
  try
    if (Id < 0) or (Id >= Length(FRow)) or (FRow[Id] < 0) then
      Exit;
    r := FRow[Id];
    for k := 0 to CLIP_DIM - 1 do
      V[k] := FVec[r * CLIP_DIM + k] * FScale[r];
  finally
    FLock.Leave;
  end;
  { CLIP's zero-shot recipe: cosines times its logit scale (100), softmax }
  SetLength(L, Length(PZ_SCENE_LABELS));
  mx := -1e9;
  for i := 0 to High(L) do
  begin
    L[i] := 0;
    for k := 0 to CLIP_DIM - 1 do
      L[i] := L[i] + V[k] * FLabels[i * CLIP_DIM + k];
    L[i] := 100 * L[i];
    mx := Max(mx, L[i]);
  end;
  sum := 0;
  for i := 0 to High(L) do
  begin
    L[i] := Exp(L[i] - mx);
    sum := sum + L[i];
  end;
  SetLength(Used, Length(L));
  SetLength(Result, Min(N, Length(L)));
  for k := 0 to High(Result) do
  begin
    b := -1;
    for i := 0 to High(L) do
      if not Used[i] and ((b < 0) or (L[i] > L[b])) then
        b := i;
    Used[b] := True;
    Result[k] := PZ_SCENE_LABELS[b];
    if k <= High(Probs) then
      Probs[k] := L[b] / sum;
  end;
end;

procedure TPzClipIndex.Execute;
var
  DB: psqlite3;
  St, Ins, Get: psqlite3_stmt;
  H, TH: Ppz_ai;
  Have: array of Boolean;
  Todo: array of Int64;
  i, n, k: Integer;
  Id: Int64;
  Img: Tpz_image;
  E: array[0..CLIP_DIM - 1] of Single;
  Blob: array[0..CLIP_DIM + 3] of Byte;
  Err: string;
  r: Integer;
begin
  H := nil;
  DB := nil;
  if sqlite3_open_v2(PAnsiChar(FDBPath), @DB, SQLITE_OPEN_READWRITE, nil) <>
    SQLITE_OK then
  begin
    FError := 'cannot open ' + FDBPath;
    Exit;
  end;
  try
    sqlite3_busy_timeout(DB, 10000);
    sqlite3_exec(DB, 'CREATE TABLE IF NOT EXISTS clip(id INTEGER PRIMARY KEY, emb BLOB)',
      nil, nil, nil);
    { what is indexed already }
    if sqlite3_prepare_v2(DB, 'SELECT id, emb FROM clip', -1, @St, nil) = SQLITE_OK then
    begin
      while not Terminated and (sqlite3_step(St) = SQLITE_ROW) do
        if sqlite3_column_bytes(St, 1) = CLIP_DIM + 4 then
          Add(sqlite3_column_int64(St, 0), E, sqlite3_column_blob(St, 1));
      sqlite3_finalize(St);
    end;
    { the scene labels, once per run (CPU, a few ms each) }
    if OpenText(TH, Err) then
    begin
      SetLength(FLabels, Length(PZ_SCENE_LABELS) * CLIP_DIM);
      for i := 0 to High(PZ_SCENE_LABELS) do
      begin
        if Terminated then
          Break;
        if pz_ai_clip_text(TH, PAnsiChar('a photo of ' + PZ_SCENE_LABELS[i]),
          @E[0]) = 0 then
          Move(E[0], FLabels[i * CLIP_DIM], CLIP_DIM * SizeOf(Single));
      end;
      pz_ai_close(TH);
      FLabelsReady := not Terminated;
    end
    else
      FError := Err;
    if pz_ai_open(PAnsiChar(ClipFile('clip_vision.mnn')), PZ_AI_OPENCL, -1,
      0, @H) <> 0 then
    begin
      FError := StrPas(pz_ai_error);
      Exit;
    end;
    sqlite3_prepare_v2(DB, 'INSERT OR REPLACE INTO clip(id, emb) VALUES(?, ?)',
      -1, @Ins, nil);
    sqlite3_prepare_v2(DB, 'SELECT data FROM thumbs WHERE id=?', -1, @Get, nil);
    while not Terminated do
    begin
      { the thumbnails without an embedding }
      Todo := nil;
      n := 0;
      FTotal := 0;
      FLock.Enter;
      SetLength(Have, Length(FRow));
      for i := 0 to High(FRow) do
        Have[i] := FRow[i] >= 0;
      FLock.Leave;
      if sqlite3_prepare_v2(DB, 'SELECT id FROM thumbs', -1, @St, nil) = SQLITE_OK then
      begin
        while sqlite3_step(St) = SQLITE_ROW do
        begin
          Id := sqlite3_column_int64(St, 0);
          Inc(FTotal);
          if (Id >= Length(Have)) or not Have[Id] then
          begin
            if n >= Length(Todo) then
              SetLength(Todo, Max(256, n * 2));
            Todo[n] := Id;
            Inc(n);
          end;
        end;
        sqlite3_finalize(St);
      end;
      { newest photos (highest ids) first }
      k := n - 1;
      while (k >= 0) and not Terminated do
      begin
        sqlite3_exec(DB, 'BEGIN', nil, nil, nil);
        for i := 0 to 63 do
        begin
          if (k < 0) or Terminated then
            Break;
          Id := Todo[k];
          Dec(k);
          sqlite3_reset(Get);
          sqlite3_bind_int64(Get, 1, Id);
          if sqlite3_step(Get) <> SQLITE_ROW then
            Continue;
          PzInit(Img);
          if pz_decode_jpeg_mem(sqlite3_column_blob(Get, 0),
            sqlite3_column_bytes(Get, 0), 0, 0, 0, @Img) <> 0 then
            Continue;
          r := pz_ai_clip_image(H, @Img, @E[0]);
          pz_free(@Img);
          if r <> 0 then
            Continue;
          Add(Id, E, nil);
          FLock.Enter;
          r := FRow[Id];
          Move(FScale[r], Blob[0], 4);
          Move(FVec[r * CLIP_DIM], Blob[4], CLIP_DIM);
          FLock.Leave;
          sqlite3_reset(Ins);
          sqlite3_bind_int64(Ins, 1, Id);
          sqlite3_bind_blob(Ins, 2, @Blob[0], CLIP_DIM + 4, nil);
          sqlite3_step(Ins);
          Inc(FAdded);
        end;
        sqlite3_exec(DB, 'COMMIT', nil, nil, nil);
      end;
      if not Terminated then
        FWake.WaitFor(30000); // new thumbnails show up as they are made
    end;
    sqlite3_finalize(Ins);
    sqlite3_finalize(Get);
  finally
    if H <> nil then
      pz_ai_close(H);
    sqlite3_close(DB);
  end;
end;

end.
