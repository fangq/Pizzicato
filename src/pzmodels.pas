{ The AI models, in per-feature zip bundles that are downloaded the first
  time a feature needs them (like siamize's weights): curl fetches
  <PZ_MODELS_URL><zip> into the model directory, the zip's SHA-256 is
  checked, and it is unpacked there. tools/package_models.sh makes the
  bundles from the converted models and prints the table below. }
unit pzmodels;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Forms, Controls, StdCtrls, ExtCtrls, ComCtrls, CheckLst,
  Dialogs, process, zipper, pzcorebind, pzai;

type
  TPzBundle = record
    Name: string;     // denoise, remove, ...
    Title: string;    // what the user sees
    Zip: string;      // the file on the server
    Bytes: Int64;     // its size
    Sha256: string;
    Files: string;    // what it installs, space separated, relative to PzAIModelDir
  end;

const
  { the server: the zip's name is appended (so a NeuroJSON-style
    "...&file=" prefix works as well as a directory URL ending in /) }
  PZ_MODELS_URL_DEFAULT = '';

  PZ_BUNDLES: array[0..6] of TPzBundle = (
    (Name: 'denoise'; Title: 'AI Denoise'; Zip: 'pizzicato-denoise-v1.zip';
    Bytes: 214624528; Sha256:
    '2e954b40f9af3272cfb878c2f3b0cb6def03e9da8ede202073aaea3339f6dd92';
    Files: 'nafnet_sidd.mnn'),
    (Name: 'denoise-hq'; Title: 'AI Denoise, high quality';
    Zip: 'pizzicato-denoise-hq-v1.zip';
    Bytes: 33512890; Sha256:
    '11d162798d0400aa5d8936eb37961dfb137ae4d74cc949920ab84d42d5af05ae';
    Files: 'scunet_real.mnn'),
    (Name: 'upscale'; Title: 'AI Upscale (on export)'; Zip: 'pizzicato-upscale-v1.zip';
    Bytes: 2293860; Sha256:
    'c2bf830b82591c29ab2b39426a3d0151d24ff8ab276579231015f270ba2d13d0';
    Files: 'esrgan_x4v3.mnn'),
    (Name: 'remove'; Title: 'Remove (select and fill in)';
    Zip: 'pizzicato-remove-v1.zip';
    Bytes: 152603577; Sha256:
    'fcb1507bcaf175c617045413f8f3e43c94b84130ac08d91ce94ad05ac1d4ffa7';
    Files: 'mobilesam_enc.mnn mobilesam_dec2.mnn mobilesam_dec3.mnn mobilesam_dec4.mnn '
    + 'mobilesam_dec5.mnn mobilesam_dec6.mnn lama.mnn'),
    (Name: 'search'; Title: 'Smart search'; Zip: 'pizzicato-search-v1.zip';
    Bytes: 279939497; Sha256:
    '98621d194efbb9d72bdd4b18b608e44a46e21f3a2131a0cca40d8ef96f323da4';
    Files: 'clip_vision.mnn clip_text.mnn clip_vocab.json clip_merges.txt'),
    (Name: 'faces'; Title: 'People (face recognition)'; Zip: 'pizzicato-faces-v1.zip';
    Bytes: 17960503; Sha256:
    '0624ded7096d23f01ce5791fe4fc918c6396e3d57cd73c10c4d48a5a88d3e5fc';
    Files: 'face_yunet.mnn face_sface.mnn'),
    (Name: 'captions'; Title: 'Scene summaries'; Zip: 'pizzicato-captions-v1.zip';
    Bytes: 273878389; Sha256:
    'a1c4105dc04dc4b4940c1e8da5f88d721fd3927a2d4c3a6e53c8aee83704c724';
    Files: 'smolvlm256m/config.json smolvlm256m/llm_config.json smolvlm256m/llm.mnn ' +
    'smolvlm256m/llm.mnn.weight smolvlm256m/visual.mnn smolvlm256m/visual.mnn.weight ' +
    'smolvlm256m/tokenizer.mtok smolvlm256m/embeddings_bf16.bin')
    );

{ PZ_MODELS_URL, else the built-in address ('' = none) }
function PzModelsURL: string;
function PzBundleIndex(const Name: string): Integer;
function PzBundleInstalled(const Name: string): Boolean;
{ the bundle a model file comes in }
function PzBundleOfKind(K: TPzAIKind): string;

type
  { downloads and installs bundles in the background }
  TPzModelFetch = class(TThread)
  private
    FList: array of Integer;
    FDone, FTotal: Int64;      // bytes
    FCurrent: string;          // the bundle being fetched
    FError: string;
    FInstalled: Integer;
    function FetchOne(b: Integer; Base: Int64): Boolean;
  protected
    procedure Execute; override;
  public
    constructor Create(const Names: array of string);
    property Done: Int64 read FDone;
    property Total: Int64 read FTotal;
    property Current: string read FCurrent;
    property Error: string read FError;
    property Installed: Integer read FInstalled;
  end;

{ The AI Models dialog: lists the bundles; Want are ticked (and what Why
  says is shown at the top). True when every bundle in Want is installed
  when it closes. }
function PzModelsDialog(const Want: array of string; const Why: string = ''): Boolean;

implementation

uses
  Math, StrUtils;

function PzModelsURL: string;
begin
  Result := GetEnvironmentVariable('PZ_MODELS_URL');
  if Result = '' then
    Result := PZ_MODELS_URL_DEFAULT;
end;

function PzBundleIndex(const Name: string): Integer;
begin
  for Result := 0 to High(PZ_BUNDLES) do
    if PZ_BUNDLES[Result].Name = Name then
      Exit;
  Result := -1;
end;

function BundleInstalled(b: Integer): Boolean;
var
  F: TStringArray;
  i: Integer;
begin
  F := PZ_BUNDLES[b].Files.Split(' ');
  for i := 0 to High(F) do
    if (F[i] <> '') and not FileExists(PzAIModelDir + '/' + F[i]) then
      Exit(False);
  Result := True;
end;

function PzBundleInstalled(const Name: string): Boolean;
var
  b: Integer;
begin
  b := PzBundleIndex(Name);
  Result := (b >= 0) and BundleInstalled(b);
end;

function PzBundleOfKind(K: TPzAIKind): string;
const
  N: array[TPzAIKind] of string = ('denoise', 'denoise-hq', 'upscale', 'remove');
begin
  Result := N[K];
end;

function MB(Bytes: Int64): string;
begin
  Result := Format('%.0f MB', [Bytes / 1048576]);
end;

{ TPzModelFetch }

constructor TPzModelFetch.Create(const Names: array of string);
var
  i, b: Integer;
begin
  FreeOnTerminate := False;
  for i := 0 to High(Names) do
  begin
    b := PzBundleIndex(Names[i]);
    if (b >= 0) and not BundleInstalled(b) then
    begin
      SetLength(FList, Length(FList) + 1);
      FList[High(FList)] := b;
      Inc(FTotal, PZ_BUNDLES[b].Bytes);
    end;
  end;
  inherited Create(False);
end;

function FileSizeOf(const Path: string): Int64;
var
  R: TSearchRec;
begin
  Result := 0;
  if FindFirst(Path, faAnyFile, R) = 0 then
  begin
    Result := R.Size;
    FindClose(R);
  end;
end;

function TPzModelFetch.FetchOne(b: Integer; Base: Int64): Boolean;
var
  Bd: TPzBundle;
  Tmp, ZipF, Unp, Url, Src, Dst: string;
  Pr: TProcess;
  Hex: array[0..64] of AnsiChar;
  U: TUnZipper;
  F: TStringArray;
  i: Integer;
begin
  Result := False;
  Bd := PZ_BUNDLES[b];
  FCurrent := Bd.Title;
  Tmp := PzAIModelDir + '/.download';
  ForceDirectories(Tmp);
  ZipF := Tmp + '/' + Bd.Zip;
  Url := PzModelsURL + Bd.Zip;
  { a complete zip from an earlier try is not fetched again; a partial one
    is resumed (-C -) }
  if FileSizeOf(ZipF) <> Bd.Bytes then
  begin
    Pr := TProcess.Create(nil);
    try
      Pr.Executable := ExeSearch('curl', GetEnvironmentVariable('PATH'));
      if Pr.Executable = '' then
      begin
        FError := 'the "curl" tool was not found';
        Exit;
      end;
      Pr.Parameters.AddStrings(['-fL', '-s', '-S', '--retry', '3',
        '-C', '-', '-o', ZipF, Url]);
      Pr.Options := [poNoConsole];
      Pr.Execute;
      while Pr.Running do
      begin
        FDone := Base + FileSizeOf(ZipF);
        if Terminated then
        begin
          Pr.Terminate(1);
          Exit;
        end;
        Sleep(200);
      end;
      if Pr.ExitStatus <> 0 then
      begin
        FError := Format('could not download %s (curl error %d)', [Url, Pr.ExitStatus]);
        Exit;
      end;
    finally
      Pr.Free;
    end;
  end;
  FDone := Base + Bd.Bytes;
  if (Bd.Sha256 <> '') and ((pz_sha256_file(PAnsiChar(ZipF), @Hex[0]) <> 0) or
    (StrPas(@Hex[0]) <> Bd.Sha256)) then
  begin
    DeleteFile(ZipF);
    FError := Bd.Zip + ' is damaged (its SHA-256 does not match): try again';
    Exit;
  end;
  { unpack beside the model directory, then move the files in, so that a
    half-unpacked bundle never looks installed }
  Unp := Tmp + '/' + Bd.Name;
  U := TUnZipper.Create;
  try
    U.FileName := ZipF;
    U.OutputPath := Unp;
    try
      U.UnZipAllFiles;
    except
      on E: Exception do
      begin
        FError := 'could not unpack ' + Bd.Zip + ': ' + E.Message;
        Exit;
      end;
    end;
  finally
    U.Free;
  end;
  F := Bd.Files.Split(' ');
  for i := 0 to High(F) do
  begin
    Src := Unp + '/' + F[i];
    Dst := PzAIModelDir + '/' + F[i];
    if not FileExists(Src) then
    begin
      FError := Bd.Zip + ' has no ' + F[i];
      Exit;
    end;
    ForceDirectories(ExtractFileDir(Dst));
    DeleteFile(Dst);
    if not RenameFile(Src, Dst) then
    begin
      FError := 'could not install ' + Dst;
      Exit;
    end;
  end;
  DeleteFile(ZipF);
  for i := 0 to High(F) do
    RemoveDir(ExtractFileDir(Unp + '/' + F[i]));
  RemoveDir(Unp);
  RemoveDir(Tmp);
  Inc(FInstalled);
  Result := True;
end;

procedure TPzModelFetch.Execute;
var
  i: Integer;
  Base: Int64;
begin
  if PzModelsURL = '' then
  begin
    FError := 'no download address is set (PZ_MODELS_URL)';
    Exit;
  end;
  Base := 0;
  for i := 0 to High(FList) do
  begin
    if Terminated or not FetchOne(FList[i], Base) then
      Break;
    Inc(Base, PZ_BUNDLES[FList[i]].Bytes);
  end;
end;

{ ---------------- the dialog ---------------- }

type
  TModelsDlg = class(TForm)
  public
    Lst: TCheckListBox;
    Bar: TProgressBar;
    Lbl: TLabel;
    BtnGet, BtnClose: TButton;
    Tmr: TTimer;
    Fetch: TPzModelFetch;
    procedure Fill;
    procedure FillClick(Sender: TObject);
    procedure GetClick(Sender: TObject);
    procedure Tick(Sender: TObject);
    procedure DoClose(Sender: TObject; var CloseAction: TCloseAction);
  end;

procedure TModelsDlg.Fill;
var
  b: Integer;
  Inst: Boolean;
  Need: Int64;
begin
  Need := 0;
  for b := 0 to High(PZ_BUNDLES) do
  begin
    Inst := BundleInstalled(b);
    Lst.Items[b] := PZ_BUNDLES[b].Title + '   ' + IfThen(Inst,
      '(installed)', MB(PZ_BUNDLES[b].Bytes));
    Lst.ItemEnabled[b] := not Inst;
    if Inst then
      Lst.Checked[b] := True
    else if Lst.Checked[b] then
      Inc(Need, PZ_BUNDLES[b].Bytes);
  end;
  BtnGet.Enabled := (Need > 0) and (Fetch = nil);
  BtnGet.Caption := IfThen(Need > 0, 'Download ' + MB(Need), 'Download');
end;

procedure TModelsDlg.FillClick(Sender: TObject);
begin
  Fill;
end;

procedure TModelsDlg.GetClick(Sender: TObject);
var
  N: array of string;
  b: Integer;
begin
  if Fetch <> nil then
    Exit;
  N := nil;
  for b := 0 to High(PZ_BUNDLES) do
    if Lst.Checked[b] and not BundleInstalled(b) then
    begin
      SetLength(N, Length(N) + 1);
      N[High(N)] := PZ_BUNDLES[b].Name;
    end;
  if Length(N) = 0 then
    Exit;
  Fetch := TPzModelFetch.Create(N);
  Lst.Enabled := False;
  BtnGet.Enabled := False;
  BtnClose.Caption := 'Cancel';
  Tmr.Enabled := True;
end;

procedure TModelsDlg.Tick(Sender: TObject);
begin
  if Fetch = nil then
    Exit;
  if Fetch.Total > 0 then
    Bar.Position := Round(1000 * Fetch.Done / Fetch.Total);
  Lbl.Caption := Format('Downloading %s ... %s of %s',
    [Fetch.Current, MB(Fetch.Done), MB(Fetch.Total)]);
  if not Fetch.Finished then
    Exit;
  Tmr.Enabled := False;
  if Fetch.Error <> '' then
    Lbl.Caption := 'Stopped: ' + Fetch.Error
  else
  begin
    Lbl.Caption := 'Installed in ' + PzAIModelDir + '.';
    Bar.Position := 1000;
  end;
  FreeAndNil(Fetch);
  Lst.Enabled := True;
  BtnClose.Caption := 'Close';
  Fill;
end;

procedure TModelsDlg.DoClose(Sender: TObject; var CloseAction: TCloseAction);
begin
  if Fetch <> nil then
  begin
    { Cancel: stop the download (a partial zip is resumed next time) }
    Fetch.Terminate;
    Fetch.WaitFor;
    FreeAndNil(Fetch);
  end;
  Tmr.Enabled := False;
end;

function PzModelsDialog(const Want: array of string; const Why: string): Boolean;
var
  D: TModelsDlg;
  b, i: Integer;
  Top: TLabel;
begin
  D := TModelsDlg.CreateNew(nil);
  try
    D.Caption := 'AI Models';
    D.Width := 460;
    D.Height := 400;
    D.Position := poOwnerFormCenter;
    D.BorderStyle := bsDialog;
    D.OnClose := @D.DoClose;
    Top := TLabel.Create(D);
    Top.Parent := D;
    Top.SetBounds(12, 10, 436, 50);
    Top.WordWrap := True;
    Top.AutoSize := False;
    Top.Caption := IfThen(Why <> '', Why + LineEnding, '') +
      'The AI tools run on this computer; each needs its model once. ' +
      'Tick the ones to download:';
    D.Lst := TCheckListBox.Create(D);
    D.Lst.Parent := D;
    D.Lst.SetBounds(12, 64, 436, 180);
    for b := 0 to High(PZ_BUNDLES) do
      D.Lst.Items.Add(PZ_BUNDLES[b].Title);
    for i := 0 to High(Want) do
    begin
      b := PzBundleIndex(Want[i]);
      if b >= 0 then
        D.Lst.Checked[b] := True;
    end;
    D.Bar := TProgressBar.Create(D);
    D.Bar.Parent := D;
    D.Bar.SetBounds(12, 254, 436, 18);
    D.Bar.Max := 1000;
    D.Lbl := TLabel.Create(D);
    D.Lbl.Parent := D;
    D.Lbl.SetBounds(12, 278, 436, 64);
    D.Lbl.AutoSize := False;
    D.Lbl.WordWrap := True;
    if PzModelsURL = '' then
      D.Lbl.Caption := 'No download address is set: start Pizzicato with ' +
        'PZ_MODELS_URL=<address>, or install the models by hand in ' + PzAIModelDir
    else
      D.Lbl.Caption := 'From ' + PzModelsURL;
    D.BtnGet := TButton.Create(D);
    D.BtnGet.Parent := D;
    D.BtnGet.SetBounds(228, 352, 130, 32);
    D.BtnGet.OnClick := @D.GetClick;
    D.BtnGet.Default := True;
    D.BtnClose := TButton.Create(D);
    D.BtnClose.Parent := D;
    D.BtnClose.SetBounds(366, 352, 82, 32);
    D.BtnClose.Caption := 'Close';
    D.BtnClose.ModalResult := mrClose;
    D.BtnClose.Cancel := True;
    D.Tmr := TTimer.Create(D);
    D.Tmr.Interval := 250;
    D.Tmr.Enabled := False;
    D.Tmr.OnTimer := @D.Tick;
    D.Fill;
    { a click on a tick box changes what Download fetches }
    D.Lst.OnClickCheck := @D.FillClick;
    D.ShowModal;
    Result := True;
    for i := 0 to High(Want) do
      if not PzBundleInstalled(Want[i]) then
        Result := False;
  finally
    D.Free;
  end;
end;

end.
