{ Scene summaries: a background indexer has SmolVLM-256M (a small
  vision-language model, on MNN-LLM) describe every photo in one sentence,
  from its cached thumbnail, into the DB's captions table. The text is kept
  in memory for the search box and the Properties panel. The captions live
  only in the DB: never in the photo's own caption= in .picasa.ini. }
unit pzcaption;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, SyncObjs, ctypes, sqlite3, pzcorebind, pzai;

type
  TPzCaptionIndex = class(TThread)
  private
    FDBPath: string;
    FLock: TCriticalSection;
    FWake: TEvent;
    FText: array of string;    // photo id -> caption ('' = none yet)
    FCount: Integer;           // captions in FText
    FTotal: Integer;           // thumbnails in the DB
    FError: string;
    FAdded: Integer;           // captions added since the app last looked
    FBackend: string;
    FSeconds: Double;          // time spent captioning this run
    FMade: Integer;            // captions made this run
    procedure Put(Id: Int64; const S: string);
  protected
    procedure Execute; override;
  public
    constructor Create(const ADBPath: string);
    destructor Destroy; override;
    procedure Stop;
    procedure Kick;            // look for new thumbnails now
    function Caption(Id: Int64): string;
    { all captions, by photo id ('-' = the captioner had nothing to say) }
    function Snapshot: TStringArray;
    property Done: Integer read FCount;
    property Total: Integer read FTotal;
    property Error: string read FError;
    property Added: Integer read FAdded write FAdded;
    property Backend: string read FBackend;
    property Made: Integer read FMade;
    property Seconds: Double read FSeconds;
  end;

{ the captioner is installed (and AI is built in); Why says what is missing }
function PzCaptionReady(out Why: string): Boolean;
function PzCaptionModelDir: string;

implementation

uses
  Math;

function pz_ai_caption_open(dir: PAnsiChar; device: cint; h: PPointer): cint;
  cdecl; external;
function pz_ai_caption(h: Ppz_ai; img: Ppz_image; text: PAnsiChar; max: cint): cint;
  cdecl; external;

function PzCaptionModelDir: string;
begin
  Result := PzAIModelDir + '/smolvlm256m';
end;

function PzCaptionReady(out Why: string): Boolean;
begin
  Why := '';
  if not PzAIAvailable then
    Why := 'This Pizzicato was built without AI support (make AI=1).'
  else if not FileExists(PzCaptionModelDir + '/config.json') or not
    FileExists(PzCaptionModelDir + '/visual.mnn') then
    Why := Format('The scene captioner is not installed in %s.' +
      LineEnding + 'Download it with AI Models... (top bar).', [PzCaptionModelDir]);
  Result := Why = '';
end;

function NowSec: Double;
begin
  Result := GetTickCount64 / 1000;
end;

{ TPzCaptionIndex }

constructor TPzCaptionIndex.Create(const ADBPath: string);
begin
  FDBPath := ADBPath;
  FLock := TCriticalSection.Create;
  FWake := TEvent.Create(nil, False, False, '');
  FreeOnTerminate := False;
  inherited Create(False);
  Priority := tpLower;
end;

destructor TPzCaptionIndex.Destroy;
begin
  Stop;
  FWake.Free;
  FLock.Free;
  inherited Destroy;
end;

procedure TPzCaptionIndex.Stop;
begin
  if Finished then
    Exit;
  Terminate;
  FWake.SetEvent;
  WaitFor;
end;

procedure TPzCaptionIndex.Kick;
begin
  FWake.SetEvent;
end;

procedure TPzCaptionIndex.Put(Id: Int64; const S: string);
var
  k: Integer;
begin
  if (Id < 0) or (S = '') then
    Exit;
  FLock.Enter;
  try
    if Id >= Length(FText) then
    begin
      k := Length(FText);
      SetLength(FText, Max(Id + 1, k * 3 div 2 + 1024));
    end;
    if FText[Id] = '' then
      Inc(FCount);
    FText[Id] := S;
  finally
    FLock.Leave;
  end;
end;

function TPzCaptionIndex.Caption(Id: Int64): string;
begin
  Result := '';
  FLock.Enter;
  try
    if (Id >= 0) and (Id < Length(FText)) and (FText[Id] <> '-') then
      Result := FText[Id];
  finally
    FLock.Leave;
  end;
end;

function TPzCaptionIndex.Snapshot: TStringArray;
begin
  FLock.Enter;
  try
    Result := Copy(FText, 0, Length(FText));
  finally
    FLock.Leave;
  end;
end;

procedure TPzCaptionIndex.Execute;
var
  DB: psqlite3;
  St, Ins, Get: psqlite3_stmt;
  H: Ppz_ai;
  Todo: array of Int64;
  i, n, k: Integer;
  Id: Int64;
  Img: Tpz_image;
  Txt: array[0..511] of AnsiChar;
  S: string;
  T0: Double;
  Have: Boolean;
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
    sqlite3_exec(DB,
      'CREATE TABLE IF NOT EXISTS captions(id INTEGER PRIMARY KEY, text TEXT)',
      nil, nil, nil);
    { what is described already }
    if sqlite3_prepare_v2(DB, 'SELECT id, text FROM captions', -1, @St, nil) =
      SQLITE_OK then
    begin
      while not Terminated and (sqlite3_step(St) = SQLITE_ROW) do
        Put(sqlite3_column_int64(St, 0), StrPas(PAnsiChar(sqlite3_column_text(St, 1))));
      sqlite3_finalize(St);
    end;
    FAdded := FCount;
    if Terminated then
      Exit;
    if pz_ai_caption_open(PAnsiChar(PzCaptionModelDir), PZ_AI_OPENCL, @H) <> 0 then
    begin
      FError := StrPas(pz_ai_error);
      Exit;
    end;
    FBackend := StrPas(pz_ai_backend(H));
    sqlite3_prepare_v2(DB, 'INSERT OR REPLACE INTO captions(id, text) VALUES(?, ?)',
      -1, @Ins, nil);
    sqlite3_prepare_v2(DB, 'SELECT data FROM thumbs WHERE id=?', -1, @Get, nil);
    while not Terminated do
    begin
      { the thumbnails without a caption }
      Todo := nil;
      n := 0;
      FTotal := 0;
      if sqlite3_prepare_v2(DB, 'SELECT id FROM thumbs', -1, @St, nil) = SQLITE_OK then
      begin
        while sqlite3_step(St) = SQLITE_ROW do
        begin
          Id := sqlite3_column_int64(St, 0);
          Inc(FTotal);
          FLock.Enter;
          Have := (Id < Length(FText)) and (FText[Id] <> '');
          FLock.Leave;
          if not Have then
          begin
            if n >= Length(Todo) then
              SetLength(Todo, Max(256, n * 2));
            Todo[n] := Id;
            Inc(n);
          end;
        end;
        sqlite3_finalize(St);
      end;
      { newest photos (highest ids) first; a few at a time per transaction,
        so other connections are not kept waiting }
      k := n - 1;
      while (k >= 0) and not Terminated do
      begin
        sqlite3_exec(DB, 'BEGIN', nil, nil, nil);
        for i := 0 to 15 do
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
          T0 := NowSec;
          Txt[0] := #0;
          if pz_ai_caption(H, @Img, @Txt[0], SizeOf(Txt)) = 0 then
          begin
            S := StrPas(@Txt[0]);
            FSeconds := FSeconds + NowSec - T0;
            Inc(FMade);
            if S = '' then
              S := '-'; // nothing to say; do not ask again
            Put(Id, S);
            sqlite3_reset(Ins);
            sqlite3_bind_int64(Ins, 1, Id);
            sqlite3_bind_text(Ins, 2, PAnsiChar(S), -1, nil);
            sqlite3_step(Ins);
            Inc(FAdded);
          end
          else if FError = '' then
            FError := StrPas(pz_ai_error);
          pz_free(@Img);
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
