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
  TPzAIKind = (akDenoise, akDenoiseHQ, akUpscale, akRemove);

  TPzAIProgressEvent = procedure(Done, Total: Integer) of object;

const
  PZ_AI_NAMES: array[TPzAIKind] of string =
    ('AI denoise', 'AI denoise (HQ)', 'AI upscale',
    'AI remove');

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
{ AI upscale by 2 or 4 in this thread (Real-ESRGAN is x4; x2 resamples its
  result down). Outputs are capped at MaxMP megapixels: a larger request is
  scaled down first. Returns 0, 1 cancelled, <0 error. }
function PzUpscale(var Img: Tpz_image; Scale: Integer; Cancel: PInteger = nil;
  MaxMP: Double = 250): Integer;
{ apply a chain's AI steps to a full image in this thread (export);
  PhotoPath finds the removal masks }
procedure PzAIApplyChain(var Img: Tpz_image; const Filters, PhotoPath: string;
  Cancel: PInteger);
{ removal masks: <album>/.pizzicato/<photo>.<k>.png, in the upright
  camera image's frame, any size }
function PzMaskPath(const PhotoPath: string; K: Integer): string;
{ the chain's pzremove steps' mask numbers, in order }
function RemoveSteps(const Filters: string): TStringArray;
{ remove the masked area of Img in this thread (LaMa) }
function PzAIInpaint(var Img: Tpz_image; const MaskFile: string): Integer;

type
  { MobileSAM in the main thread: one image's embedding, then masks }
  TPzSam = class
  private
    FEnc, FDec: Ppz_ai;
    FEmb: array of Single;
    FW, FH: Integer;
    FKey: string;
    FError: string;
  public
    destructor Destroy; override;
    { compute the embedding of Img unless Key is the one already there }
    function Embed(const Key: string; const Img: Tpz_image): Boolean;
    { points: x, y pairs in Img pixels; labels 1 = subject, 0 = keep }
    function Mask(const Pts: array of Single; const Labels: array of Integer;
      out M: TBytes): Boolean;
    property W: Integer read FW;
    property H: Integer read FH;
    property Error: string read FError;
  end;

type
  TPzAIJob = class
  public
    Kind: TPzAIKind;
    Key: string;        // what the result is of: photo, its version, model, size
    CachePath: string;  // on-disk copy of the result ('' = none)
    Tag: Pointer;       // the photo
    Img: Tpz_image;     // input; the result when OK
    MaskFile: string;   // akRemove: the mask
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
    'esrgan_x4v3.mnn', 'lama.mnn');
  { overlap between tiles, in input pixels }
  MODEL_OVERLAP: array[TPzAIKind] of Integer = (32, 32, 8, 0);
  MODEL_TILE: array[TPzAIKind] of Integer = (0, 256, 0, -1);

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

function PzUpscale(var Img: Tpz_image; Scale: Integer; Cancel: PInteger;
  MaxMP: Double): Integer;
var
  TW, TH: Integer;
  f: Double;
  T: Tpz_image;
begin
  Result := 0;
  if (Scale <= 1) or (Img.px = nil) then
    Exit;
  TW := Img.w * Scale;
  TH := Img.h * Scale;
  { the x4 model's output must fit too: shrink the input when needed }
  f := Sqrt(MaxMP * 1e6 / (Img.w * 4.0 * Img.h * 4.0));
  if f < 1 then
  begin
    PzInit(T);
    if pz_resize(@Img, Max(1, Round(Img.w * f)), Max(1, Round(Img.h * f)), @T) <> 0 then
      Exit(-1);
    pz_free(@Img);
    Img := T;
    if TW * Double(TH) > MaxMP * 1e6 then
    begin
      f := Sqrt(MaxMP * 1e6 / (TW * Double(TH)));
      TW := Round(TW * f);
      TH := Round(TH * f);
    end;
  end;
  Result := PzAIRun(akUpscale, Img, Cancel);
  if (Result = 0) and ((Img.w <> TW) or (Img.h <> TH)) then
  begin
    PzInit(T);
    if pz_resize(@Img, TW, TH, @T) = 0 then
    begin
      pz_free(@Img);
      Img := T;
    end;
  end;
end;

procedure PzAIApplyChain(var Img: Tpz_image; const Filters, PhotoPath: string;
  Cancel: PInteger);
var
  A: Double;
  K: TPzAIKind;
  D: Tpz_image;
  R: TStringArray;
  i: Integer;
begin
  if DenoiseOf(Filters, A, K) then
  begin
    PzInit(D);
    if pz_copy(@Img, @D) = 0 then
    begin
      if PzAIRun(K, D, Cancel) = 0 then
        PzMix(Img, D, A);
      pz_free(@D);
    end;
  end;
  R := RemoveSteps(Filters);
  for i := 0 to High(R) do
    PzAIInpaint(Img, PzMaskPath(PhotoPath, StrToIntDef(R[i], 0)));
end;

function PzMaskPath(const PhotoPath: string; K: Integer): string;
begin
  Result := ExtractFilePath(PhotoPath) + '.pizzicato/' +
    ExtractFileName(PhotoPath) + '.' + IntToStr(K) + '.png';
end;

function RemoveSteps(const Filters: string): TStringArray;
var
  C: TPzChain;
  i: Integer;
begin
  Result := nil;
  if Pos('pzremove', Filters) = 0 then
    Exit;
  C := ParseChain(Filters);
  for i := 0 to High(C) do
    if (C[i].Name = 'pzremove') and (Length(C[i].Args) > 0) then
    begin
      SetLength(Result, Length(Result) + 1);
      Result[High(Result)] := C[i].Args[0];
    end;
end;

function pz_ai_sam_encode(enc: Ppz_ai; img: Ppz_image; emb: PSingle): cint;
  cdecl; external;
function pz_ai_sam_mask(dec: Ppz_ai; emb: PSingle; w, h: cint;
  pts: PSingle; labels: PInteger; n: cint; mask: PByte): cint; cdecl; external;
function pz_ai_inpaint(lama: Ppz_ai; img: Ppz_image; mask: PByte): cint; cdecl; external;

const
  SAM_EMB = 256 * 64 * 64;

{ a mask file sampled to W x H bytes (nonzero = remove) }
function LoadMask(const F: string; W, H: Integer; out M: TBytes): Boolean;
var
  Img: Tpz_image;
  Meta: Tpz_meta;
  x, y: Integer;
begin
  Result := False;
  M := nil;
  PzInit(Img);
  if pz_load(PAnsiChar(F), 0, 0, 0, @Img, @Meta) < 0 then
    Exit;
  SetLength(M, W * H);
  for y := 0 to H - 1 do
    for x := 0 to W - 1 do
      if (Img.px[(y * Img.h div H) * Img.w + (x * Img.w div W)] and $FF) > 127 then
        M[y * W + x] := 255
      else
        M[y * W + x] := 0;
  pz_free(@Img);
  Result := True;
end;

function PzAIInpaint(var Img: Tpz_image; const MaskFile: string): Integer;
var
  H: Ppz_ai;
  Why: string;
  M: TBytes;
begin
  TLastError := '';
  if not PzAIReady(akRemove, Why) then
  begin
    TLastError := Why;
    Exit(-1);
  end;
  if not LoadMask(MaskFile, Img.w, Img.h, M) then
  begin
    TLastError := 'cannot read the mask ' + MaskFile;
    Exit(-1);
  end;
  H := THandles[akRemove];
  if H = nil then
  begin
    if pz_ai_open(PAnsiChar(PzAIModelFile(akRemove)), PZ_AI_OPENCL, -1, 0, @H) <> 0 then
    begin
      TLastError := StrPas(pz_ai_error);
      Exit(-1);
    end;
    THandles[akRemove] := H;
  end;
  Result := pz_ai_inpaint(H, @Img, @M[0]);
  if Result <> 0 then
    TLastError := StrPas(pz_ai_error);
end;

{ TPzSam }

destructor TPzSam.Destroy;
begin
  if FEnc <> nil then
    pz_ai_close(FEnc);
  if FDec <> nil then
    pz_ai_close(FDec);
  inherited Destroy;
end;

function TPzSam.Embed(const Key: string; const Img: Tpz_image): Boolean;
var
  Dir: string;
begin
  Result := (Key = FKey) and (FEmb <> nil);
  if Result then
    Exit;
  FError := '';
  Dir := PzAIModelDir + '/';
  if not PzAIAvailable or not FileExists(Dir + 'mobilesam_enc.mnn') or
    not FileExists(Dir + 'mobilesam_dec2.mnn') then
  begin
    FError := 'The subject-selection model (MobileSAM) is not installed in ' +
      PzAIModelDir + '. Run tools/fetch_models.sh mobilesam.';
    Exit;
  end;
  if (FEnc = nil) and (pz_ai_open(PAnsiChar(Dir + 'mobilesam_enc.mnn'),
    PZ_AI_OPENCL, -1, 0, @FEnc) <> 0) then
  begin
    FError := StrPas(pz_ai_error);
    Exit;
  end;
  if (FDec = nil) and (pz_ai_open(PAnsiChar(Dir + 'mobilesam_dec.mnn'),
    PZ_AI_CPU, -1, 0, @FDec) <> 0) then
  begin
    FError := StrPas(pz_ai_error);
    Exit;
  end;
  SetLength(FEmb, SAM_EMB);
  Result := pz_ai_sam_encode(FEnc, @Img, @FEmb[0]) = 0;
  if Result then
  begin
    FKey := Key;
    FW := Img.w;
    FH := Img.h;
  end
  else
  begin
    FError := StrPas(pz_ai_error);
    FEmb := nil;
    FKey := '';
  end;
end;

function TPzSam.Mask(const Pts: array of Single; const Labels: array of Integer;
  out M: TBytes): Boolean;
begin
  M := nil;
  Result := False;
  if (FEmb = nil) or (Length(Labels) = 0) then
    Exit;
  SetLength(M, FW * FH);
  Result := pz_ai_sam_mask(FDec, @FEmb[0], FW, FH, @Pts[0], @Labels[0],
    Length(Labels), @M[0]) = 0;
  if not Result then
    FError := StrPas(pz_ai_error);
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
      if J.Kind = akRemove then
        rc := PzAIInpaint(J.Img, J.MaskFile)
      else
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
