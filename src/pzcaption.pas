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
    FAuto: Boolean;            // describe every new photo; else only on request
    FWork: TPzWorkList;
    FJobDone, FJobTotal: Integer;
    procedure Put(Id: Int64; const S: string);
  protected
    procedure Execute; override;
  public
    constructor Create(const ADBPath: string; AAuto: Boolean = True);
    destructor Destroy; override;
    procedure Stop;
    procedure Kick;            // look for new thumbnails now
    { manual mode: describe these photos (those without a caption yet) }
    procedure Request(Id: Int64);
    procedure RequestAll;
    procedure Cancel;
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
    property Auto: Boolean read FAuto;
    { the photos of the run in progress (manual mode) }
    property JobDone: Integer read FJobDone;
    property JobTotal: Integer read FJobTotal;
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

constructor TPzCaptionIndex.Create(const ADBPath: string; AAuto: Boolean);
begin
  FDBPath := ADBPath;
  FAuto := AAuto;
  FWork := TPzWorkList.Create;
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
  FWork.Free;
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

procedure TPzCaptionIndex.Request(Id: Int64);
begin
  FWork.Add(Id);
  FWake.SetEvent;
end;

procedure TPzCaptionIndex.RequestAll;
begin
  FWork.AddAll;
  FWake.SetEvent;
end;

procedure TPzCaptionIndex.Cancel;
begin
  FWork.Cancel;
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
  i, n, k, k2, nb: Integer;
  BId: array[0..15] of Int64;
  BText: array[0..15] of string;
  Id: Int64;
  Img: Tpz_image;
  Txt: array[0..511] of AnsiChar;
  S: string;
  T0: Double;
  Have, All: Boolean;
  Want: TPzBoolArray;

  function Stopped: Boolean;
  begin
    Result := Terminated or (not FAuto and FWork.Cancelled);
  end;

begin
  H := nil;
  DB := nil;
  Ins := nil;
  Get := nil;
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
    sqlite3_prepare_v2(DB, 'INSERT OR REPLACE INTO captions(id, text) VALUES(?, ?)',
      -1, @Ins, nil);
    sqlite3_prepare_v2(DB, 'SELECT data FROM thumbs WHERE id=?', -1, @Get, nil);
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
      { the model goes on the GPU only once there is work }
      if H = nil then
      begin
        if pz_ai_caption_open(PAnsiChar(PzCaptionModelDir), PZ_AI_OPENCL, @H) <> 0 then
        begin
          FError := StrPas(pz_ai_error);
          H := nil;
          Break;
        end;
        FBackend := StrPas(pz_ai_backend(H));
      end;
      { the thumbnails without a caption (of those asked for) }
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
          if not Have and (All or ((Id < Length(Want)) and Want[Id])) then
          begin
            if n >= Length(Todo) then
              SetLength(Todo, Max(256, n * 2));
            Todo[n] := Id;
            Inc(n);
          end;
        end;
        sqlite3_finalize(St);
      end;
      { newest photos (highest ids) first, 16 at a time. The captioning
        runs outside any transaction; each batch is then written in one
        short write transaction. (A deferred transaction that reads first
        cannot write once another connection has committed meanwhile:
        SQLITE_BUSY_SNAPSHOT, which no busy timeout cures.) }
      FJobTotal := n;
      FJobDone := 0;
      k := n - 1;
      while (k >= 0) and not Stopped do
      begin
        nb := 0;
        for i := 0 to 15 do
        begin
          if (k < 0) or Stopped then
            Break;
          Inc(FJobDone);
          Id := Todo[k];
          Dec(k);
          sqlite3_reset(Get);
          sqlite3_bind_int64(Get, 1, Id);
          if sqlite3_step(Get) <> SQLITE_ROW then
          begin
            sqlite3_reset(Get);
            Continue;
          end;
          PzInit(Img);
          k2 := pz_decode_jpeg_mem(sqlite3_column_blob(Get, 0),
            sqlite3_column_bytes(Get, 0), 0, 0, 0, @Img);
          sqlite3_reset(Get); // do not keep a read open
          if k2 <> 0 then
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
            BId[nb] := Id;
            BText[nb] := S;
            Inc(nb);
          end
          else if FError = '' then
            FError := StrPas(pz_ai_error);
          pz_free(@Img);
        end;
        if nb > 0 then
        begin
          sqlite3_exec(DB, 'BEGIN IMMEDIATE', nil, nil, nil);
          for i := 0 to nb - 1 do
          begin
            sqlite3_reset(Ins);
            sqlite3_bind_int64(Ins, 1, BId[i]);
            sqlite3_bind_text(Ins, 2, PAnsiChar(BText[i]), -1, nil);
            sqlite3_step(Ins);
          end;
          sqlite3_exec(DB, 'COMMIT', nil, nil, nil);
          Inc(FAdded, nb);
        end;
      end;
      FJobTotal := 0;
      FJobDone := 0;
      if FAuto and not Terminated then
        FWake.WaitFor(30000); // new thumbnails show up as they are made
    end;
  finally
    sqlite3_finalize(Ins);
    sqlite3_finalize(Get);
    if H <> nil then
      pz_ai_close(H);
    sqlite3_close(DB);
  end;
end;

end.
