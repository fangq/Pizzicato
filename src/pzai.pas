{ AI image operations (core/pzai.h on MNN/OpenCL): the model files, a
  synchronous runner for background threads, and the GPU worker thread the
  editor queues its jobs on. Without `make AI=1` PzAIAvailable is False and
  everything here reports so. }
unit pzai;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, SyncObjs, ctypes, pzcorebind, pzini;

const
  PZ_AI_CPU = 0;
  PZ_AI_OPENCL = 1;
  PZ_AI_VULKAN = 2;

type
  Ppz_ai = Pointer;
  Tpz_ai_progress = function(user: Pointer; done, total: cint): cint; cdecl;

function pz_ai_available: cint; cdecl; external;
function pz_ai_error: PAnsiChar; cdecl; external;
procedure pz_ai_set_cache_dir(dir: PAnsiChar); cdecl; external;
function pz_ai_open(model: PAnsiChar; device, tile, threads: cint; h: PPointer): cint;
  cdecl; external;
procedure pz_ai_close(h: Ppz_ai); cdecl; external;
function pz_ai_backend(h: Ppz_ai): PAnsiChar; cdecl; external;
function pz_ai_tile(h: Ppz_ai): cint; cdecl; external;
function pz_ai_scale(h: Ppz_ai): cint; cdecl; external;
function pz_ai_run_tiled(h: Ppz_ai; img, out_: Ppz_image;
  overlap, rx, ry, rw, rh: cint; cb: Tpz_ai_progress; user: Pointer): cint;
  cdecl; external;

type
  TPzAIKind = (akDenoise, akDenoiseHQ, akUpscale);

  TPzAIProgressEvent = procedure(Done, Total: Integer) of object;

const
  PZ_AI_NAMES: array[TPzAIKind] of string =
    ('AI denoise', 'AI denoise (HQ)', 'AI upscale');

{ built with MNN }
function PzAIAvailable: Boolean;
{ where the .mnn files are: $PZ_MODELS, else ~/.local/share/pizzicato/models }
function PzAIModelDir: string;
function PzAIModelFile(K: TPzAIKind): string;
{ available and the model file is there; Why says what is missing }
function PzAIReady(K: TPzAIKind; out Why: string): Boolean;
{ Run a model over Img in this thread (replaced by the result). Cancel, when
  given, is polled between tiles. Returns 0, 1 cancelled, <0 error. Each
  thread keeps its own model handles open until PzAICloseThread. }
function PzAIRun(K: TPzAIKind; var Img: Tpz_image; Cancel: PInteger = nil;
  Progress: TPzAIProgressEvent = nil): Integer;
procedure PzAICloseThread;
function PzAILastError: string;
{ Img := Img + Amount * (Other - Img), per channel; same size }
procedure PzMix(var Img: Tpz_image; const Other: Tpz_image; Amount: Double);
{ the chain's AI denoise step (pzdenoise=1,<amount>,<hq>;, always first) }
function DenoiseOf(const Filters: string; out Amount: Double; out K: TPzAIKind): Boolean;
{ apply a chain's AI steps to a full image in this thread (export) }
procedure PzAIApplyChain(var Img: Tpz_image; const Filters: string; Cancel: PInteger);

type
  TPzAIJob = class
  public
    Kind: TPzAIKind;
    Key: string;        // what the result is of: photo, its version, model, size
    CachePath: string;  // on-disk copy of the result ('' = none)
    Tag: Pointer;       // the photo
    Img: Tpz_image;     // input; the result when OK
    OK: Boolean;
    Cancel: Integer;    // set to 1 to stop it between tiles
    Error: string;
    Seconds: Double;
    FromCache: Boolean;
    destructor Destroy; override;
  end;

  TPzAIJobEvent = procedure(J: TPzAIJob) of object;
  TPzAIProgressInfo = procedure(Tag: Pointer; Done, Total: Integer) of object;

  { one thread, so one GPU queue; newest job first }
  TPzAIWorker = class(TThread)
  private
    FLock: TCriticalSection;
    FEvent: TEvent;
    FQueue: TList;
    FCurrent: TPzAIJob;
    FDone: TList;
    FOnDone: TPzAIJobEvent;
    FOnProgress: TPzAIProgressInfo;
    FProgTag: Pointer;
    FProgDone, FProgTotal: Integer;
    procedure Deliver;
    procedure DeliverProgress;
    procedure JobProgress(Done, Total: Integer);
  protected
    procedure Execute; override;
  public
    constructor Create;
    destructor Destroy; override;
    procedure Submit(J: TPzAIJob);
    { is a job with this key queued or running? }
    function Pending(const Key: string): Boolean;
    { cancel the queued and running jobs whose Tag is not Keep }
    procedure CancelOthers(Keep: Pointer);
    procedure Stop;
    property OnDone: TPzAIJobEvent read FOnDone write FOnDone;
    property OnProgress: TPzAIProgressInfo read FOnProgress write FOnProgress;
    property ProgressDone: Integer read FProgDone;
    property ProgressTotal: Integer read FProgTotal;
  end;

implementation

uses
  Math, pzlibrary;

const
  MODEL_FILES: array[TPzAIKind] of string = ('nafnet_sidd.mnn', 'scunet_real.mnn',
    'esrgan_x4v3.mnn');
  { overlap between tiles, in input pixels }
  MODEL_OVERLAP: array[TPzAIKind] of Integer = (32, 32, 8);
  MODEL_TILE: array[TPzAIKind] of Integer = (0, 256, 0);

threadvar
  THandles: array[TPzAIKind] of Ppz_ai;
  TLastError: string;

type
  TRunCtx = record
    Cancel: PInteger;
    Progress: TPzAIProgressEvent;
  end;
  PRunCtx = ^TRunCtx;

function PzAIAvailable: Boolean;
begin
  Result := pz_ai_available <> 0;
end;

function PzAIModelDir: string;
begin
  Result := GetEnvironmentVariable('PZ_MODELS');
  if Result = '' then
    Result := GetEnvironmentVariable('HOME') + '/.local/share/pizzicato/models';
  Result := ExcludeTrailingPathDelimiter(Result);
end;

function PzAIModelFile(K: TPzAIKind): string;
begin
  Result := PzAIModelDir + '/' + MODEL_FILES[K];
end;

function PzAIReady(K: TPzAIKind; out Why: string): Boolean;
begin
  Why := '';
  if not PzAIAvailable then
    Why := 'This Pizzicato was built without AI support (make AI=1).'
  else if not FileExists(PzAIModelFile(K)) then
    Why := Format('The model %s is not installed in %s.' + LineEnding +
      'Run tools/fetch_models.sh to download it.', [MODEL_FILES[K], PzAIModelDir]);
  Result := Why = '';
end;

function PzAILastError: string;
begin
  Result := TLastError;
end;

function RunProgress(user: Pointer; done, total: cint): cint; cdecl;
var
  C: PRunCtx;
begin
  C := PRunCtx(user);
  if Assigned(C^.Progress) then
    C^.Progress(done, total);
  if (C^.Cancel <> nil) and (C^.Cancel^ <> 0) then
    Result := 1
  else
    Result := 0;
end;

function PzAIRun(K: TPzAIKind; var Img: Tpz_image; Cancel: PInteger;
  Progress: TPzAIProgressEvent): Integer;
var
  H: Ppz_ai;
  Dev: Integer;
  Why: string;
  Outp: Tpz_image;
  Ctx: TRunCtx;
begin
  TLastError := '';
  if not PzAIReady(K, Why) then
  begin
    TLastError := Why;
    Exit(-1);
  end;
  H := THandles[K];
  if H = nil then
  begin
    if GetEnvironmentVariable('PZ_AI_DEVICE') = 'cpu' then
      Dev := PZ_AI_CPU
    else
      Dev := PZ_AI_OPENCL;
    if pz_ai_open(PAnsiChar(PzAIModelFile(K)), Dev, MODEL_TILE[K], 0, @H) <> 0 then
    begin
      TLastError := StrPas(pz_ai_error);
      Exit(-1);
    end;
    THandles[K] := H;
  end;
  PzInit(Outp);
  Ctx.Cancel := Cancel;
  Ctx.Progress := Progress;
  Result := pz_ai_run_tiled(H, @Img, @Outp, MODEL_OVERLAP[K], 0, 0,
    0, 0, @RunProgress, @Ctx);
  if Result = 0 then
  begin
    pz_free(@Img);
    Img := Outp;
  end
  else
  begin
    if Result < 0 then
      TLastError := StrPas(pz_ai_error);
    pz_free(@Outp);
  end;
end;

procedure PzAICloseThread;
var
  K: TPzAIKind;
begin
  for K := Low(TPzAIKind) to High(TPzAIKind) do
    if THandles[K] <> nil then
    begin
      pz_ai_close(THandles[K]);
      THandles[K] := nil;
    end;
end;

procedure PzMix(var Img: Tpz_image; const Other: Tpz_image; Amount: Double);
var
  i, n, a, c, sh: Integer;
  p, q: LongWord;
  r: LongWord;
begin
  if (Img.px = nil) or (Other.px = nil) or (Img.w <> Other.w) or (Img.h <> Other.h) then
    Exit;
  a := Round(EnsureRange(Amount, 0, 1) * 256);
  n := Img.w * Img.h;
  if a >= 256 then
  begin
    Move(Other.px^, Img.px^, n * 4);
    Exit;
  end;
  for i := 0 to n - 1 do
  begin
    p := Img.px[i];
    q := Other.px[i];
    r := p and $FF000000;
    for c := 0 to 2 do
    begin
      sh := c * 8;
      r := r or (LongWord((Integer((p shr sh) and 255) * (256 - a) +
        Integer((q shr sh) and 255) * a + 128) shr 8) shl sh);
    end;
    Img.px[i] := r;
  end;
end;

function DenoiseOf(const Filters: string; out Amount: Double; out K: TPzAIKind): Boolean;
var
  C: TPzChain;
begin
  Amount := 0;
  K := akDenoise;
  Result := Pos('pzdenoise', Filters) > 0;
  if not Result then
    Exit;
  C := ParseChain(Filters);
  Result := (Length(C) > 0) and (C[0].Name = 'pzdenoise');
  if Result then
  begin
    Amount := FArg(C[0], 0, 0.8);
    if FArg(C[0], 1, 0) >= 0.5 then
      K := akDenoiseHQ;
  end;
end;

procedure PzAIApplyChain(var Img: Tpz_image; const Filters: string; Cancel: PInteger);
var
  A: Double;
  K: TPzAIKind;
  D: Tpz_image;
begin
  if not DenoiseOf(Filters, A, K) then
    Exit;
  PzInit(D);
  if pz_copy(@Img, @D) <> 0 then
    Exit;
  if PzAIRun(K, D, Cancel) = 0 then
    PzMix(Img, D, A);
  pz_free(@D);
end;

{ TPzAIJob }

destructor TPzAIJob.Destroy;
begin
  pz_free(@Img);
  inherited Destroy;
end;

{ TPzAIWorker }

constructor TPzAIWorker.Create;
begin
  FLock := TCriticalSection.Create;
  FEvent := TEvent.Create(nil, False, False, '');
  FQueue := TList.Create;
  FDone := TList.Create;
  FreeOnTerminate := False;
  inherited Create(False);
end;

destructor TPzAIWorker.Destroy;
var
  i: Integer;
begin
  Stop;
  for i := 0 to FQueue.Count - 1 do
    TPzAIJob(FQueue[i]).Free;
  for i := 0 to FDone.Count - 1 do
    TPzAIJob(FDone[i]).Free;
  FQueue.Free;
  FDone.Free;
  FEvent.Free;
  FLock.Free;
  inherited Destroy;
end;

procedure TPzAIWorker.Stop;
begin
  if Finished then
    Exit;
  Terminate;
  FLock.Enter;
  if FCurrent <> nil then
    FCurrent.Cancel := 1;
  FLock.Leave;
  FEvent.SetEvent;
  WaitFor;
end;

procedure TPzAIWorker.Submit(J: TPzAIJob);
begin
  FLock.Enter;
  FQueue.Insert(0, J);
  FLock.Leave;
  FEvent.SetEvent;
end;

function TPzAIWorker.Pending(const Key: string): Boolean;
var
  i: Integer;
begin
  Result := False;
  FLock.Enter;
  try
    if (FCurrent <> nil) and (FCurrent.Key = Key) and (FCurrent.Cancel = 0) then
      Exit(True);
    for i := 0 to FQueue.Count - 1 do
      if TPzAIJob(FQueue[i]).Key = Key then
        Exit(True);
  finally
    FLock.Leave;
  end;
end;

procedure TPzAIWorker.CancelOthers(Keep: Pointer);
var
  i: Integer;
begin
  FLock.Enter;
  try
    for i := FQueue.Count - 1 downto 0 do
      if TPzAIJob(FQueue[i]).Tag <> Keep then
      begin
        TPzAIJob(FQueue[i]).Free;
        FQueue.Delete(i);
      end;
    if (FCurrent <> nil) and (FCurrent.Tag <> Keep) then
      FCurrent.Cancel := 1;
  finally
    FLock.Leave;
  end;
end;

procedure TPzAIWorker.JobProgress(Done, Total: Integer);
begin
  FProgDone := Done;
  FProgTotal := Total;
  { a few updates a second is plenty }
  if (Done = 1) or (Done = Total) or (Done mod Max(1, Total div 20) = 0) then
    Queue(@DeliverProgress);
end;

procedure TPzAIWorker.DeliverProgress;
begin
  if Assigned(FOnProgress) and not Terminated then
    FOnProgress(FProgTag, FProgDone, FProgTotal);
end;

procedure TPzAIWorker.Deliver;
var
  L: TList;
  i: Integer;
begin
  FLock.Enter;
  L := FDone;
  FDone := TList.Create;
  FLock.Leave;
  for i := 0 to L.Count - 1 do
    if Assigned(FOnDone) and not Terminated then
      FOnDone(TPzAIJob(L[i]))
    else
      TPzAIJob(L[i]).Free;
  L.Free;
end;

procedure TPzAIWorker.Execute;
var
  J: TPzAIJob;
  T0: Double;
  Buf: PByte;
  Len: culong;
  Ms: TMemoryStream;
  Done: Tpz_image;
  rc: Integer;
begin
  while not Terminated do
  begin
    J := nil;
    FLock.Enter;
    if FQueue.Count > 0 then
    begin
      J := TPzAIJob(FQueue[0]);
      FQueue.Delete(0);
    end;
    FCurrent := J;
    FLock.Leave;
    if J = nil then
    begin
      FEvent.WaitFor(500);
      Continue;
    end;
    T0 := NowSeconds;
    { a result computed before comes from the disk cache }
    if (J.CachePath <> '') and FileExists(J.CachePath) then
    begin
      Ms := TMemoryStream.Create;
      try
        Ms.LoadFromFile(J.CachePath);
        PzInit(Done);
        if (pz_decode_jpeg_mem(Ms.Memory, Ms.Size, 0, 0, 0, @Done) = 0) and
          (Done.w = J.Img.w) and (Done.h = J.Img.h) then
        begin
          pz_free(@J.Img);
          J.Img := Done;
          J.OK := True;
          J.FromCache := True;
        end
        else
          pz_free(@Done);
      except
        J.OK := False;
      end;
      Ms.Free;
    end;
    if not J.OK then
    begin
      FProgTag := J.Tag;
      rc := PzAIRun(J.Kind, J.Img, @J.Cancel, @JobProgress);
      J.OK := rc = 0;
      if rc < 0 then
        J.Error := PzAILastError;
      if J.OK and (J.CachePath <> '') then
      begin
        { keep it for next time: JPEG at q97 is quick to write and read back }
        Buf := nil;
        if pz_encode_jpeg_mem(@J.Img, 97, @Buf, @Len) = 0 then
        begin
          ForceDirectories(ExtractFileDir(J.CachePath));
          Ms := TMemoryStream.Create;
          try
            Ms.WriteBuffer(Buf^, Len);
            try
              Ms.SaveToFile(J.CachePath + '.part');
              RenameFile(J.CachePath + '.part', J.CachePath);
            except
              DeleteFile(J.CachePath + '.part');
            end;
          finally
            Ms.Free;
          end;
          pz_free_mem(Buf);
        end;
      end;
    end;
    J.Seconds := NowSeconds - T0;
    FLock.Enter;
    FCurrent := nil;
    FDone.Add(J);
    FLock.Leave;
    Queue(@Deliver);
  end;
  PzAICloseThread;
end;

end.
