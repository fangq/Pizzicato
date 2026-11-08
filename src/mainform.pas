{ Pizzicato main window: library mode (folder tree + continuous grid) and
  edit mode (Picasa-style Basic Fixes / Tuning / Effects panel, viewer,
  filmstrip). Also hosts the --bench driver. }
unit mainform;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Forms, Controls, Graphics, StdCtrls, ExtCtrls, ComCtrls, Dialogs,
  LCLType, LCLIntf, IniFiles, Math, Menus, DateUtils,
  pzcorebind, pzini, pzrender, pzlibrary, pzviews;

type
  TViewEntry = class
    Photo: TPzPhoto;
    Img: Tpz_image;
    Level: Integer;     // 1 = embedded preview only, 2 = view quality, 3 = full resolution
    BoxW, BoxH: Integer;
    Stamp: Int64;
    destructor Destroy; override;
  end;

  TSliderKind = (skFill, skTilt, skTFill, skTHigh, skTShadow, skTTemp,
    skBright, skContrast,
    skSharpen, skSat, skBoost, skSoft, skVignette);

  { TMainForm }

  TMainForm = class(TForm)
  private
    Lib: TPzLibrary;
    Settings: TIniFile;
    { library mode }
    PnlTop: TPanel;
    BtnAdd: TButton;
    EdSearch: TEdit;
    ChkStar: TCheckBox;
    ChkRawPreview: TCheckBox;
    TrkSize: TTrackBar;
    LblStatus: TLabel;
    PnlLibrary: TPanel;
    Tree: TTreeView;
    Splitter: TSplitter;
    Grid: TPzGrid;
    { edit mode }
    PnlEdit: TPanel;
    PnlEditTop: TPanel;
    BtnBack, BtnStar, BtnRotL, BtnRotR, BtnZoom, BtnExport, BtnUndo,
    BtnRedo, BtnUndoAll: TButton;
    LblName: TLabel;
    PnlTools: TPanel;
    Pages: TPageControl;
    Viewer: TPzViewer;
    Strip: TPzStrip;
    Sliders: array[TSliderKind] of TTrackBar;
    CmbAspect: TComboBox;
    BtnCrop, BtnCropApply, BtnCropCancel, BtnPick: TButton;
    LblInfo: TLabel;
    Status: TStatusBar;
    TmrIni, TmrStatus: TTimer;
    { state }
    FEditMode: Boolean;
    Cur: TPzPhoto;
    ViewToken: Integer;
    Cache: TList;
    CacheClock: Int64;
    FUpdatingUI: Boolean;
    FRenderQueued: Boolean;
    FTreeSync: Boolean;
    FTreeDirty: Boolean;
    FDirtyFolders: TList;
    FCurLevel: Integer;        // quality level currently displayed
    FLastRenderMs: Double;
    FOpenT0: Double;
    FFirstFullMs: Double;
    { bench }
    FBench: Boolean;
    FBenchLog: TextFile;
    FBenchLogOpen: Boolean;
    FGenAll: Boolean;
    FOpenFile: string;
    procedure TryOpenFile;
    procedure BuildUI;
    procedure BuildEditPanel;
    function AddSlider(AParent: TWinControl; const ACaption: string;
      AMin, AMax: Integer; K: TSliderKind; var Y: Integer): TTrackBar;
    function AddButton(AParent: TWinControl; const ACaption: string;
      X, Y, W: Integer; Handler: TNotifyEvent): TButton;
    procedure LibResult(R: TPzResult);
    procedure LibScanDir(Sender: TObject);
    procedure LibScanDone(Sender: TObject);
    procedure RebuildTree;
    procedure TreeChange(Sender: TObject; Node: TTreeNode);
    procedure GridTopFolder(Sender: TObject);
    procedure GridOpen(Sender: TObject; P: TPzPhoto);
    procedure GridSelect(Sender: TObject; P: TPzPhoto);
    procedure StripPick(Sender: TObject; P: TPzPhoto);
    procedure SizeChange(Sender: TObject);
    procedure SearchChange(Sender: TObject);
    procedure StarChange(Sender: TObject);
    procedure RawModeChange(Sender: TObject);
    procedure AddFolderClick(Sender: TObject);
    procedure BackClick(Sender: TObject);
    procedure StarClick(Sender: TObject);
    procedure RotLClick(Sender: TObject);
    procedure RotRClick(Sender: TObject);
    procedure ZoomClick(Sender: TObject);
    procedure ExportClick(Sender: TObject);
    procedure UndoClick(Sender: TObject);
    procedure RedoClick(Sender: TObject);
    procedure UndoAllClick(Sender: TObject);
    procedure SliderChange(Sender: TObject);
    procedure EffectClick(Sender: TObject);
    procedure CropClick(Sender: TObject);
    procedure CropApplyClick(Sender: TObject);
    procedure CropCancelClick(Sender: TObject);
    procedure AspectChange(Sender: TObject);
    procedure PickClick(Sender: TObject);
    procedure ViewerPick(Sender: TObject; NX, NY: Double);
    procedure TmrIniTimer(Sender: TObject);
    procedure TmrStatusTimer(Sender: TObject);
    procedure FormKeyDown(Sender: TObject; var Key: Word; Shift: TShiftState);
    procedure FormClose(Sender: TObject; var CloseAction: TCloseAction);
    procedure FormShow(Sender: TObject);
    procedure ViewerResize(Sender: TObject);
    procedure SetEditMode(AOn: Boolean);
    function ViewBox(P: TPzPhoto; out W, H: Integer): Boolean;
    function RawFlags: Integer;
    function CacheFind(P: TPzPhoto; MinLevel: Integer): TViewEntry;
    procedure CachePut(R: TPzResult);
    procedure CacheTrim;
    procedure RequestViews(P: TPzPhoto; Front: Boolean);
    procedure ShowPhoto(P: TPzPhoto);
    procedure Navigate(Delta: Integer);
    procedure QueueRender;
    procedure DoQueuedRender(Data: PtrInt);
    procedure RenderCurrent;
    procedure LoadSlidersFromChain;
    procedure ApplySlider(K: TSliderKind);
    procedure SetLastFilter(const AName: string; const AArgs: array of string);
    procedure AppendFilter(const AName: string; const AArgs: array of string);
    procedure EditsChanged(P: TPzPhoto);
    procedure FlushInis;
    procedure UpdateStatus;
    procedure ToggleStar(P: TPzPhoto);
    procedure RotatePhoto(P: TPzPhoto; Delta: Integer);
    procedure ExportPhotos(L: TList; const Dir: string);
    { bench }
    procedure BLog(const S: string);
    procedure BenchWait(Cond: Integer; TimeoutSec: Double; out Elapsed: Double);
    function BenchCond(Cond: Integer): Boolean;
    procedure RunBench;
    procedure RunGenAll;
    procedure RunBenchAsync(Data: PtrInt);
    procedure RunGenAllAsync(Data: PtrInt);
    procedure BenchViewer(F: TPzFolder; N: Integer; Dwell: Double);
    procedure BenchEdit(P: TPzPhoto);
  public
    constructor Create(TheOwner: TComponent); override;
    destructor Destroy; override;
  end;

var
  MainFrm: TMainForm;
  PzStartTime: Double;

implementation

const
  BC_VISIBLE = 1;
  BC_VIEWFULL = 2;
  BC_SCANDONE = 3;
  BC_GENDONE = 4;

function UnixToDateTimeSafe(T: Int64): TDateTime;
begin
  if T <= 0 then
    Result := EncodeDate(1970, 1, 1)
  else
    Result := UnixToDateTime(T);
end;

{ TViewEntry }

destructor TViewEntry.Destroy;
begin
  pz_free(@Img);
  inherited Destroy;
end;

{ TMainForm }

constructor TMainForm.Create(TheOwner: TComponent);
var
  i: Integer;
  A, DBPath, LogPath: string;
  CfgDir: string;
begin
  inherited CreateNew(TheOwner);
  Cache := TList.Create;
  FDirtyFolders := TList.Create;
  CfgDir := GetEnvironmentVariable('HOME') + '/.config/pizzicato';
  ForceDirectories(CfgDir);
  Settings := TIniFile.Create(CfgDir + '/settings.ini');
  { thumbnail cache: $PZ_DB, else $XDG_CACHE_HOME, else ~/.cache (keep it on
    a local disk: SQLite WAL on NFS is slow and unsafe) }
  DBPath := GetEnvironmentVariable('PZ_DB');
  if DBPath = '' then
  begin
    CfgDir := GetEnvironmentVariable('XDG_CACHE_HOME');
    if CfgDir = '' then
      CfgDir := GetEnvironmentVariable('HOME') + '/.cache';
    DBPath := CfgDir + '/pizzicato/library.db';
  end;
  CfgDir := GetEnvironmentVariable('HOME') + '/.config/pizzicato';
  LogPath := '';
  for i := 1 to ParamCount do
  begin
    A := ParamStr(i);
    if A = '--bench' then
      FBench := True
    else if Copy(A, 1, 8) = '--bench=' then
    begin
      FBench := True;
      LogPath := Copy(A, 9, MaxInt);
    end
    else if Copy(A, 1, 6) = '--log=' then
      LogPath := Copy(A, 7, MaxInt)
    else if A = '--gen-all' then
      FGenAll := True
    else if Copy(A, 1, 5) = '--db=' then
      DBPath := Copy(A, 6, MaxInt)
    else if A = '--readonly' then
      PzIniReadOnly := True;
  end;
  if FBench or FGenAll then
    PzIniReadOnly := True; // never touch the user's .picasa.ini while benchmarking
  if LogPath <> '' then
  begin
    AssignFile(FBenchLog, LogPath);
    Rewrite(FBenchLog);
    FBenchLogOpen := True;
  end;
  Lib := TPzLibrary.Create(DBPath);
  Lib.OnResult := @LibResult;
  Lib.OnScanDir := @LibScanDir;
  Lib.OnScanDone := @LibScanDone;
  { roots: command line wins, else settings, else ~/Pictures }
  for i := 1 to ParamCount do
  begin
    A := ParamStr(i);
    if (A <> '') and (A[1] <> '-') and DirectoryExists(A) then
      Lib.AddRoot(ExcludeTrailingPathDelimiter(ExpandFileName(A)))
    else if (A <> '') and (A[1] <> '-') and FileExists(A) then
    begin
      { a single photo: show its folder and open it in the editor }
      FOpenFile := ExpandFileName(A);
      Lib.AddRoot(ExtractFileDir(FOpenFile));
    end;
  end;
  if Lib.Roots.Count = 0 then
  begin
    Lib.Roots.Delimiter := ';';
    Lib.Roots.StrictDelimiter := True;
    Lib.Roots.DelimitedText := Settings.ReadString('library', 'roots', '');
    for i := Lib.Roots.Count - 1 downto 0 do
      if Lib.Roots[i] = '' then
        Lib.Roots.Delete(i);
    if (Lib.Roots.Count = 0) and DirectoryExists(GetEnvironmentVariable('HOME') +
      '/Pictures') then
      Lib.AddRoot(GetEnvironmentVariable('HOME') + '/Pictures');
  end;
  BuildUI;
  OnKeyDown := @FormKeyDown;
  OnClose := @FormClose;
  OnShow := @FormShow;
  KeyPreview := True;
  Lib.LoadFromDB;
  BLog(Format('db-load: %d folders, %d ms since start',
    [Lib.Folders.Count, Round((NowSeconds - PzStartTime) * 1000)]));
  Grid.Lib := Lib;
  Strip.Lib := Lib;
  Lib.StartWorkers(Max(2, Min(16, PzCPUCount)));
end;

destructor TMainForm.Destroy;
var
  i: Integer;
begin
  for i := 0 to Cache.Count - 1 do
    TViewEntry(Cache[i]).Free;
  Cache.Free;
  FDirtyFolders.Free;
  Settings.Free;
  if FBenchLogOpen then
    CloseFile(FBenchLog);
  inherited Destroy;
end;

procedure TMainForm.FormShow(Sender: TObject);
begin
  OnShow := nil;
  RebuildTree;
  Grid.Relayout;
  if FGenAll then
    Application.QueueAsyncCall(@RunGenAllAsync, 0)
  else if FBench then
    Application.QueueAsyncCall(@RunBenchAsync, 0)
  else
  begin
    TryOpenFile;
    Lib.StartScan;
    Lib.QueueBackgroundGen;
  end;
end;

procedure TMainForm.BuildUI;
var
  L: TLabel;
begin
  Caption := 'Pizzicato';
  Width := Settings.ReadInteger('window', 'width', 1500);
  Height := Settings.ReadInteger('window', 'height', 950);
  Position := poScreenCenter;
  Color := clPzBack;

  Status := TStatusBar.Create(Self);
  Status.Parent := Self;
  Status.SimplePanel := True;

  { ---- library mode ---- }
  PnlTop := TPanel.Create(Self);
  PnlTop.Parent := Self;
  PnlTop.Align := alTop;
  PnlTop.Height := 40;
  PnlTop.BevelOuter := bvNone;
  PnlTop.Color := TColor($303030);

  BtnAdd := AddButton(PnlTop, 'Add Folder…', 8, 6, 100, @AddFolderClick);
  EdSearch := TEdit.Create(Self);
  EdSearch.Parent := PnlTop;
  EdSearch.SetBounds(118, 7, 220, 26);
  EdSearch.TextHint := 'Search folders';
  EdSearch.OnChange := @SearchChange;
  ChkStar := TCheckBox.Create(Self);
  ChkStar.Parent := PnlTop;
  ChkStar.SetBounds(350, 10, 90, 22);
  ChkStar.Caption := 'Starred';
  ChkStar.Font.Color := clPzHeader;
  ChkStar.OnChange := @StarChange;
  ChkRawPreview := TCheckBox.Create(Self);
  ChkRawPreview.Parent := PnlTop;
  ChkRawPreview.SetBounds(440, 10, 200, 22);
  ChkRawPreview.Caption := 'RAW: use camera preview';
  ChkRawPreview.Font.Color := clPzHeader;
  ChkRawPreview.Checked := Settings.ReadBool('view', 'rawpreview', True);
  ChkRawPreview.OnChange := @RawModeChange;
  L := TLabel.Create(Self);
  L.Parent := PnlTop;
  L.SetBounds(650, 12, 40, 20);
  L.Caption := 'Size';
  L.Font.Color := clPzHeader;
  TrkSize := TTrackBar.Create(Self);
  TrkSize.Parent := PnlTop;
  TrkSize.SetBounds(690, 4, 180, 32);
  TrkSize.Min := 64;
  TrkSize.Max := 320;
  TrkSize.Frequency := 32;
  TrkSize.Position := Settings.ReadInteger('view', 'thumbsize', 160);
  TrkSize.OnChange := @SizeChange;
  TrkSize.TabStop := False;
  LblStatus := TLabel.Create(Self);
  LblStatus.Parent := PnlTop;
  LblStatus.SetBounds(890, 12, 500, 20);
  LblStatus.Font.Color := clPzSub;

  PnlLibrary := TPanel.Create(Self);
  PnlLibrary.Parent := Self;
  PnlLibrary.Align := alClient;
  PnlLibrary.BevelOuter := bvNone;

  Tree := TTreeView.Create(Self);
  Tree.Parent := PnlLibrary;
  Tree.Align := alLeft;
  Tree.Width := Settings.ReadInteger('window', 'tree', 250);
  Tree.ReadOnly := True;
  Tree.BackgroundColor := TColor($2E2E2E);
  Tree.Color := TColor($2E2E2E);
  Tree.Font.Color := clPzHeader;
  Tree.OnChange := @TreeChange;
  Tree.TabStop := False;
  Tree.Options := Tree.Options + [tvoRowSelect] - [tvoShowRoot];

  Splitter := TSplitter.Create(Self);
  Splitter.Parent := PnlLibrary;
  Splitter.Align := alLeft;
  Splitter.Left := Tree.Width + 1;

  Grid := TPzGrid.Create(Self);
  Grid.Parent := PnlLibrary;
  Grid.Align := alClient;
  Grid.ThumbSize := TrkSize.Position;
  Grid.OnOpen := @GridOpen;
  Grid.OnSelect := @GridSelect;
  Grid.OnTopFolder := @GridTopFolder;

  { ---- edit mode ---- }
  PnlEdit := TPanel.Create(Self);
  PnlEdit.Parent := Self;
  PnlEdit.Align := alClient;
  PnlEdit.BevelOuter := bvNone;
  PnlEdit.Visible := False;
  BuildEditPanel;

  TmrIni := TTimer.Create(Self);
  TmrIni.Enabled := False;
  TmrIni.Interval := 1500;
  TmrIni.OnTimer := @TmrIniTimer;
  TmrStatus := TTimer.Create(Self);
  TmrStatus.Interval := 500;
  TmrStatus.OnTimer := @TmrStatusTimer;
end;

function TMainForm.AddButton(AParent: TWinControl; const ACaption: string;
  X, Y, W: Integer; Handler: TNotifyEvent): TButton;
begin
  Result := TButton.Create(Self);
  Result.Parent := AParent;
  Result.SetBounds(X, Y, W, 28);
  Result.Caption := ACaption;
  Result.OnClick := Handler;
  Result.TabStop := False;
end;

function TMainForm.AddSlider(AParent: TWinControl; const ACaption: string;
  AMin, AMax: Integer; K: TSliderKind; var Y: Integer): TTrackBar;
var
  L: TLabel;
begin
  L := TLabel.Create(Self);
  L.Parent := AParent;
  L.SetBounds(10, Y, 220, 18);
  L.Caption := ACaption;
  Inc(Y, 18);
  Result := TTrackBar.Create(Self);
  Result.Parent := AParent;
  Result.SetBounds(6, Y, 236, 30);
  Result.Min := AMin;
  Result.Max := AMax;
  Result.Frequency := (AMax - AMin) div 10;
  Result.Position := 0;
  Result.Tag := Ord(K);
  Result.OnChange := @SliderChange;
  Result.TabStop := False;
  Result.ShowSelRange := False;
  Sliders[K] := Result;
  Inc(Y, 36);
end;

procedure TMainForm.BuildEditPanel;
var
  TS: TTabSheet;
  Y: Integer;
  B: TButton;

  procedure Eff(const Cap, Name: string; X, YY: Integer);
  var
    BB: TButton;
  begin
    BB := AddButton(TS, Cap, X, YY, 112, @EffectClick);
    BB.Hint := Name;
  end;

begin
  PnlEditTop := TPanel.Create(Self);
  PnlEditTop.Parent := PnlEdit;
  PnlEditTop.Align := alTop;
  PnlEditTop.Height := 40;
  PnlEditTop.BevelOuter := bvNone;
  PnlEditTop.Color := TColor($303030);
  BtnBack := AddButton(PnlEditTop, '◀ Library', 8, 6, 96, @BackClick);
  BtnStar := AddButton(PnlEditTop, '☆ Star', 112, 6, 70, @StarClick);
  BtnRotL := AddButton(PnlEditTop, '⟲', 188, 6, 36, @RotLClick);
  BtnRotR := AddButton(PnlEditTop, '⟳', 228, 6, 36, @RotRClick);
  BtnZoom := AddButton(PnlEditTop, '1:1', 270, 6, 44, @ZoomClick);
  BtnExport := AddButton(PnlEditTop, 'Export…', 320, 6, 80, @ExportClick);
  LblName := TLabel.Create(Self);
  LblName.Parent := PnlEditTop;
  LblName.SetBounds(420, 12, 900, 20);
  LblName.Font.Color := clPzHeader;

  PnlTools := TPanel.Create(Self);
  PnlTools.Parent := PnlEdit;
  PnlTools.Align := alLeft;
  PnlTools.Width := 262;
  PnlTools.BevelOuter := bvNone;

  BtnUndo := AddButton(PnlTools, 'Undo', 6, 4, 80, @UndoClick);
  BtnRedo := AddButton(PnlTools, 'Redo', 90, 4, 80, @RedoClick);
  BtnUndoAll := AddButton(PnlTools, 'Undo all', 174, 4, 82, @UndoAllClick);

  Pages := TPageControl.Create(Self);
  Pages.Parent := PnlTools;
  Pages.SetBounds(0, 38, 262, 560);
  Pages.Anchors := [akLeft, akTop, akRight, akBottom];
  Pages.TabStop := False;

  { Basic fixes }
  TS := Pages.AddTabSheet;
  TS.Caption := 'Basic';
  BtnCrop := AddButton(TS, 'Crop', 8, 8, 112, @CropClick);
  CmbAspect := TComboBox.Create(Self);
  CmbAspect.Parent := TS;
  CmbAspect.SetBounds(128, 8, 116, 28);
  CmbAspect.Style := csDropDownList;
  CmbAspect.Items.CommaText := 'Free,"4:3","3:2","16:9","1:1","5:4","3:4","2:3"';
  CmbAspect.ItemIndex := 0;
  CmbAspect.OnChange := @AspectChange;
  CmbAspect.TabStop := False;
  BtnCropApply := AddButton(TS, 'Apply crop', 8, 40, 112, @CropApplyClick);
  BtnCropCancel := AddButton(TS, 'Cancel', 128, 40, 116, @CropCancelClick);
  BtnCropApply.Enabled := False;
  BtnCropCancel.Enabled := False;
  Eff('I''m Feeling Lucky', 'enhance', 8, 78);
  Eff('Auto Contrast', 'autolight', 8, 110);
  Eff('Auto Color', 'autocolor', 128, 110);
  Y := 150;
  AddSlider(TS, 'Straighten', -100, 100, skTilt, Y);
  AddSlider(TS, 'Fill Light', 0, 100, skFill, Y);

  { Tuning }
  TS := Pages.AddTabSheet;
  TS.Caption := 'Tuning';
  Y := 8;
  AddSlider(TS, 'Fill Light', 0, 100, skTFill, Y);
  AddSlider(TS, 'Highlights', 0, 100, skTHigh, Y);
  AddSlider(TS, 'Shadows', 0, 100, skTShadow, Y);
  AddSlider(TS, 'Color Temperature', -100, 100, skTTemp, Y);
  BtnPick := AddButton(TS, 'Neutral Color Picker', 8, Y, 236, @PickClick);
  Inc(Y, 40);
  AddSlider(TS, 'Brightness', -100, 100, skBright, Y);
  AddSlider(TS, 'Contrast', -100, 100, skContrast, Y);

  { Effects }
  TS := Pages.AddTabSheet;
  TS.Caption := 'Effects';
  Eff('Black && White', 'bw', 8, 8);
  Eff('Sepia', 'sepia', 128, 8);
  Eff('Warmify', 'warm', 8, 40);
  Y := 80;
  AddSlider(TS, 'Sharpen', 0, 100, skSharpen, Y);
  AddSlider(TS, 'Saturation', 0, 100, skSat, Y);
  AddSlider(TS, 'Boost', 0, 100, skBoost, Y);
  AddSlider(TS, 'Soft Focus', 0, 100, skSoft, Y);
  AddSlider(TS, 'Vignette', 0, 100, skVignette, Y);

  LblInfo := TLabel.Create(Self);
  LblInfo.Parent := PnlTools;
  LblInfo.SetBounds(8, 604, 248, 200);
  LblInfo.Anchors := [akLeft, akBottom];
  LblInfo.AutoSize := False;
  LblInfo.WordWrap := True;
  LblInfo.Font.Color := clPzSub;

  Strip := TPzStrip.Create(Self);
  Strip.Parent := PnlEdit;
  Strip.Align := alBottom;
  Strip.Height := 84;
  Strip.OnPick := @StripPick;

  Viewer := TPzViewer.Create(Self);
  Viewer.Parent := PnlEdit;
  Viewer.Align := alClient;
  Viewer.OnPick := @ViewerPick;
  Viewer.OnResize := @ViewerResize;
  B := nil;
  if B = nil then;
end;

{ ---------------- library events ---------------- }

procedure TMainForm.LibResult(R: TPzResult);
var
  B: TBitmap;
begin
  case R.Kind of
    jkThumb:
      if R.OK and (R.Img.px <> nil) then
      begin
        B := ImageToBitmap(R.Img);
        R.Photo.BmpSize := R.Size;
        R.Photo.BmpEdits := R.Edits + '|' + IntToStr(R.Rotate);
        Grid.ThumbArrived(R.Photo, B);
        if FEditMode then
        begin
          Strip.Invalidate;
          if (R.Photo = Cur) and (FCurLevel = 0) then
            Viewer.SetPlaceholder(R.Photo.Bmp);
        end;
      end;
    jkView:
    begin
      if R.Flags and PZ_PREVIEW_ONLY = 0 then
        R.Photo.ViewPending := False;
      if R.OK then
        CachePut(R);
    end;
  end;
end;

procedure TMainForm.LibScanDir(Sender: TObject);
begin
  FTreeDirty := True;
  Grid.Relayout;
  TryOpenFile;
end;

procedure TMainForm.TryOpenFile;
var
  i, k: Integer;
  F: TPzFolder;
begin
  if FOpenFile = '' then
    Exit;
  for i := 0 to Lib.Folders.Count - 1 do
  begin
    F := TPzFolder(Lib.Folders[i]);
    if F.Path = ExtractFileDir(FOpenFile) then
      for k := 0 to F.Count - 1 do
        if F.Photo(k).Name = ExtractFileName(FOpenFile) then
        begin
          FOpenFile := '';
          Grid.Relayout;
          Grid.Select(F.Photo(k));
          GridOpen(Grid, F.Photo(k));
          Exit;
        end;
  end;
end;

procedure TMainForm.LibScanDone(Sender: TObject);
begin
  RebuildTree;
  Grid.Relayout;
  if not FBench and not FGenAll then
    Lib.QueueBackgroundGen;
end;

procedure TMainForm.RebuildTree;
var
  i: Integer;
  F: TPzFolder;
  Year, LastYear: string;
  YNode, N: TTreeNode;
begin
  FTreeDirty := False;
  FTreeSync := True;
  Tree.BeginUpdate;
  try
    Tree.Items.Clear;
    YNode := nil;
    LastYear := #0;
    for i := 0 to Lib.Folders.Count - 1 do
    begin
      F := TPzFolder(Lib.Folders[i]);
      Year := FormatDateTime('yyyy', UnixToDateTimeSafe(F.SortDate));
      if Year <> LastYear then
      begin
        YNode := Tree.Items.Add(nil, Year);
        LastYear := Year;
      end;
      N := Tree.Items.AddChildObject(YNode, F.Name + '  (' + IntToStr(F.Count) + ')', F);
      if N = nil then;
    end;
    if Tree.Items.Count > 0 then
      Tree.Items[0].Expand(False);
  finally
    Tree.EndUpdate;
    FTreeSync := False;
  end;
end;

procedure TMainForm.TreeChange(Sender: TObject; Node: TTreeNode);
begin
  if FTreeSync or (Node = nil) then
    Exit;
  if Node.Data <> nil then
    Grid.ScrollToFolder(TPzFolder(Node.Data))
  else if Node.HasChildren and (Node.GetFirstChild <> nil) then
    Grid.ScrollToFolder(TPzFolder(Node.GetFirstChild.Data));
end;

procedure TMainForm.GridTopFolder(Sender: TObject);
var
  F: TPzFolder;
  N: TTreeNode;
begin
  F := Grid.TopFolder;
  if F = nil then
    Exit;
  N := Tree.Items.FindNodeWithData(F);
  if (N <> nil) and (Tree.Selected <> N) then
  begin
    FTreeSync := True;
    try
      Tree.Selected := N;
      N.MakeVisible;
    finally
      FTreeSync := False;
    end;
  end;
end;

procedure TMainForm.GridOpen(Sender: TObject; P: TPzPhoto);
begin
  SetEditMode(True);
  ShowPhoto(P);
end;

procedure TMainForm.GridSelect(Sender: TObject; P: TPzPhoto);
begin
  UpdateStatus;
end;

procedure TMainForm.StripPick(Sender: TObject; P: TPzPhoto);
begin
  ShowPhoto(P);
end;

procedure TMainForm.SizeChange(Sender: TObject);
begin
  Grid.ThumbSize := TrkSize.Position;
  Strip.ThumbSize := TrkSize.Position;
end;

procedure TMainForm.SearchChange(Sender: TObject);
begin
  Grid.Filter := EdSearch.Text;
end;

procedure TMainForm.StarChange(Sender: TObject);
begin
  Grid.StarOnly := ChkStar.Checked;
end;

procedure TMainForm.RawModeChange(Sender: TObject);
var
  i: Integer;
begin
  for i := 0 to Cache.Count - 1 do
    TViewEntry(Cache[i]).Free;
  Cache.Clear;
  if FEditMode and (Cur <> nil) then
    ShowPhoto(Cur);
end;

procedure TMainForm.AddFolderClick(Sender: TObject);
var
  Dir: string;
begin
  if SelectDirectory('Add a photo folder to the library',
    GetEnvironmentVariable('HOME'), Dir) then
  begin
    Lib.AddRoot(ExcludeTrailingPathDelimiter(Dir));
    Lib.Roots.Delimiter := ';';
    Lib.Roots.StrictDelimiter := True;
    Settings.WriteString('library', 'roots', Lib.Roots.DelimitedText);
    Lib.StartScan;
  end;
end;

{ ---------------- edit mode ---------------- }

procedure TMainForm.SetEditMode(AOn: Boolean);
begin
  if FEditMode = AOn then
    Exit;
  FEditMode := AOn;
  Viewer.SetMode(vmNormal);
  PnlEdit.Visible := AOn;
  PnlLibrary.Visible := not AOn;
  PnlTop.Visible := not AOn;
  if AOn then
    Viewer.SetFocus
  else
  begin
    FlushInis;
    if Cur <> nil then
    begin
      Grid.Select(Cur);
      Grid.EnsureVisible(Cur);
    end;
    Grid.SetFocus;
    Grid.Invalidate;
  end;
end;

function TMainForm.RawFlags: Integer;
begin
  if ChkRawPreview.Checked then
    Result := 0
  else
    Result := PZ_NO_PREVIEW;
end;

{ decode box for the viewer, enlarged for cropped photos }
function TMainForm.ViewBox(P: TPzPhoto; out W, H: Integer): Boolean;
var
  zf: Double;
  t: Integer;
begin
  W := Max(320, Viewer.ClientWidth);
  H := Max(240, Viewer.ClientHeight);
  zf := ChainZoomFactor(ParseChain(P.Filters));
  W := Min(8000, Round(W / zf));
  H := Min(8000, Round(H / zf));
  if Odd(P.Rotate) then
  begin
    t := W;
    W := H;
    H := t;
  end;
  Result := True;
end;

function TMainForm.CacheFind(P: TPzPhoto; MinLevel: Integer): TViewEntry;
var
  i: Integer;
  E: TViewEntry;
begin
  Result := nil;
  for i := 0 to Cache.Count - 1 do
  begin
    E := TViewEntry(Cache[i]);
    if (E.Photo = P) and (E.Level >= MinLevel) and
      ((Result = nil) or (E.Level > Result.Level)) then
      Result := E;
  end;
  if Result <> nil then
  begin
    Inc(CacheClock);
    Result.Stamp := CacheClock;
  end;
end;

procedure TMainForm.CacheTrim;
var
  i, Oldest: Integer;
begin
  while Cache.Count > 10 do
  begin
    Oldest := -1;
    for i := 0 to Cache.Count - 1 do
      if (TViewEntry(Cache[i]).Photo <> Cur) and
        ((Oldest < 0) or (TViewEntry(Cache[i]).Stamp <
        TViewEntry(Cache[Oldest]).Stamp)) then
        Oldest := i;
    if Oldest < 0 then
      Break;
    TViewEntry(Cache[Oldest]).Free;
    Cache.Delete(Oldest);
  end;
end;

procedure TMainForm.CachePut(R: TPzResult);
var
  E: TViewEntry;
  Lvl, i: Integer;
begin
  if R.Flags and PZ_PREVIEW_ONLY <> 0 then
    Lvl := 1
  else if (R.Flags and PZ_RAW_FULL <> 0) and (R.Token < 0) then
    Lvl := 3
  else
    Lvl := 2;
  if CacheFind(R.Photo, Lvl) <> nil then
    Exit; // already have something at least as good
  { replace lower levels of the same photo }
  for i := Cache.Count - 1 downto 0 do
    if (TViewEntry(Cache[i]).Photo = R.Photo) and (TViewEntry(Cache[i]).Level < Lvl) then
    begin
      TViewEntry(Cache[i]).Free;
      Cache.Delete(i);
    end;
  E := TViewEntry.Create;
  E.Photo := R.Photo;
  E.Img := R.Img;
  PzInit(R.Img); // steal
  E.Level := Lvl;
  Inc(CacheClock);
  E.Stamp := CacheClock;
  Cache.Add(E);
  CacheTrim;
  if (R.Photo = Cur) and (Lvl > FCurLevel) then
  begin
    if (Lvl < 3) or Viewer.Zoom100 then
      RenderCurrent;
  end;
end;

procedure TMainForm.RequestViews(P: TPzPhoto; Front: Boolean);
var
  W, H: Integer;
begin
  if (P = nil) or P.ViewPending or (CacheFind(P, 2) <> nil) then
    Exit;
  ViewBox(P, W, H);
  if Front and P.IsRaw then
    Lib.RequestView(P, W, H, PZ_PREVIEW_ONLY, ViewToken, True);
  P.ViewPending := True;
  if Front then
    Lib.RequestView(P, W, H, RawFlags, ViewToken, True)
  else
    Lib.RequestView(P, W, H, RawFlags, 0, False);
end;

procedure TMainForm.ShowPhoto(P: TPzPhoto);
var
  N: TPzPhoto;
begin
  if P = nil then
    Exit;
  if (Cur <> nil) and (Cur <> P) then
    Viewer.SetMode(vmNormal);
  Cur := P;
  Inc(ViewToken);
  FCurLevel := 0;
  FOpenT0 := NowSeconds;
  FFirstFullMs := -1;
  Viewer.Zoom100 := False;
  BtnCropApply.Enabled := False;
  BtnCropCancel.Enabled := False;
  P.Folder.EnsureIni;
  LblName.Caption := Format('%s    %s', [P.Name, P.Folder.Path]);
  if P.Star then BtnStar.Caption := '★ Star'
  else
    BtnStar.Caption := '☆ Star';
  Strip.SetCurrent(P);
  LoadSlidersFromChain;
  { drop stale prefetches, keep only what's useful now }
  Lib.CancelViews(-1);
  if CacheFind(P, 1) <> nil then
    RenderCurrent
  else
  begin
    Viewer.SetPlaceholder(P.Bmp);
    if P.Bmp = nil then
    begin
      P.WantEpoch := Lib.Epoch;
      Lib.RequestThumb(P, Grid.ThumbSize);
    end;
  end;
  RequestViews(P, True);
  { prefetch neighbours: next two and the previous one }
  N := Grid.NextPhoto(P, 1);
  RequestViews(N, False);
  RequestViews(Grid.NextPhoto(P, -1), False);
  if N <> nil then
    RequestViews(Grid.NextPhoto(N, 1), False);
  UpdateStatus;
end;

procedure TMainForm.Navigate(Delta: Integer);
var
  N: TPzPhoto;
begin
  N := Grid.NextPhoto(Cur, Delta);
  if N <> nil then
    ShowPhoto(N);
end;

procedure TMainForm.QueueRender;
begin
  if FRenderQueued then
    Exit;
  FRenderQueued := True;
  Application.QueueAsyncCall(@DoQueuedRender, 0);
end;

procedure TMainForm.DoQueuedRender(Data: PtrInt);
begin
  FRenderQueued := False;
  RenderCurrent;
end;

procedure TMainForm.RenderCurrent;
var
  E: TViewEntry;
  Img, Tmp: Tpz_image;
  T0, s: Double;
  W, H: Integer;
  Info: string;
begin
  if Cur = nil then
    Exit;
  if Viewer.Zoom100 then
    E := CacheFind(Cur, 3)
  else
    E := nil;
  if E = nil then
    E := CacheFind(Cur, 1);
  if E = nil then
    Exit;
  T0 := NowSeconds;
  if pz_copy(@E.Img, @Img) <> 0 then
    Exit;
  RenderChain(Img, ParseChain(Cur.Filters), Cur.Rotate);
  if not Viewer.Zoom100 then
  begin
    W := Max(1, Viewer.ClientWidth - 8);
    H := Max(1, Viewer.ClientHeight - 8);
    s := Min(W / Img.w, H / Img.h);
    if s < 1 then
    begin
      pz_resize(@Img, Max(1, Round(Img.w * s)), Max(1, Round(Img.h * s)), @Tmp);
      pz_free(@Img);
      Img := Tmp;
    end;
  end;
  Viewer.SetImage(ImageToBitmap(Img));
  pz_free(@Img);
  FCurLevel := E.Level;
  FLastRenderMs := (NowSeconds - T0) * 1000;
  if (E.Level >= 2) and (FFirstFullMs < 0) then
    FFirstFullMs := (NowSeconds - FOpenT0) * 1000;
  case E.Level of
    1: Info := 'preview';
    2: Info := 'screen';
    3: Info := '100%';
  end;
  Viewer.Info := Format('%dx%d  %s  ·  %s  ·  render %.0f ms',
    [Cur.W, Cur.H, Cur.Camera, Info, FLastRenderMs]);
  Viewer.Invalidate;
end;

procedure TMainForm.ViewerResize(Sender: TObject);
begin
  if FEditMode and (Cur <> nil) then
    QueueRender;
end;

{ ---------------- edits ---------------- }

procedure TMainForm.LoadSlidersFromChain;
var
  C: TPzChain;
  L: TPzFilter;
  K: TSliderKind;
  Has: Boolean;
begin
  FUpdatingUI := True;
  try
    for K := Low(TSliderKind) to High(TSliderKind) do
      Sliders[K].Position := 0;
    if Cur = nil then
      Exit;
    C := ParseChain(Cur.Filters);
    Has := Length(C) > 0;
    if not Has then
      Exit;
    L := C[High(C)];
    { like Picasa, sliders reflect the most recent filter of their kind
      only when it is the last step of the chain }
    if L.Name = 'fill' then Sliders[skFill].Position := Round(FArg(L, 0) * 100)
    else if L.Name = 'tilt' then Sliders[skTilt].Position := Round(FArg(L, 0) * 100)
    else if L.Name = 'finetune2' then
    begin
      Sliders[skTFill].Position := Round(FArg(L, 0) * 100);
      Sliders[skTHigh].Position := Round(FArg(L, 1) * 100);
      Sliders[skTShadow].Position := Round(FArg(L, 2) * 100);
      Sliders[skTTemp].Position := Round(FArg(L, 4) * 100);
    end
    else if L.Name = 'pzbc' then
    begin
      Sliders[skBright].Position := Round(FArg(L, 0) * 100);
      Sliders[skContrast].Position := Round(FArg(L, 1) * 100);
    end
    else if L.Name = 'unsharp2' then Sliders[skSharpen].Position :=
        Round(FArg(L, 0) * 100)
    else if L.Name = 'sat' then Sliders[skSat].Position := Round(FArg(L, 0) * 100)
    else if L.Name = 'Boost' then Sliders[skBoost].Position :=
        Round(FArg(L, 0) / 12 * 100)
    else if L.Name = 'pzsoft' then Sliders[skSoft].Position := Round(FArg(L, 0) * 100)
    else if L.Name = 'pzvignette' then Sliders[skVignette].Position :=
        Round(FArg(L, 0) * 100);
  finally
    FUpdatingUI := False;
  end;
end;

procedure TMainForm.EditsChanged(P: TPzPhoto);
begin
  P.Folder.SavePhotoEdits(P);
  if FDirtyFolders.IndexOf(P.Folder) < 0 then
    FDirtyFolders.Add(P.Folder);
  TmrIni.Enabled := False;
  TmrIni.Enabled := True;
  if P = Cur then
    QueueRender;
  Grid.Invalidate;
end;

procedure TMainForm.FlushInis;
var
  i: Integer;
begin
  TmrIni.Enabled := False;
  for i := 0 to FDirtyFolders.Count - 1 do
    TPzFolder(FDirtyFolders[i]).FlushIni;
  FDirtyFolders.Clear;
end;

procedure TMainForm.TmrIniTimer(Sender: TObject);
begin
  FlushInis;
end;

procedure TMainForm.SetLastFilter(const AName: string; const AArgs: array of string);
var
  C: TPzChain;
  i: Integer;
begin
  if Cur = nil then
    Exit;
  C := ParseChain(Cur.Filters);
  if (Length(C) > 0) and (C[High(C)].Name = AName) then
  begin
    SetLength(C[High(C)].Args, Length(AArgs));
    for i := 0 to High(AArgs) do
      C[High(C)].Args[i] := AArgs[i];
  end
  else
  begin
    ChainAppend(C, MakeFilter(AName, AArgs));
    Cur.Redo := '';
  end;
  Cur.Filters := ChainToString(C);
  EditsChanged(Cur);
end;

procedure TMainForm.AppendFilter(const AName: string; const AArgs: array of string);
var
  C: TPzChain;
begin
  if Cur = nil then
    Exit;
  C := ParseChain(Cur.Filters);
  ChainAppend(C, MakeFilter(AName, AArgs));
  Cur.Redo := '';
  Cur.Filters := ChainToString(C);
  EditsChanged(Cur);
  LoadSlidersFromChain;
end;

function SV(T: TTrackBar): string;
begin
  Result := FmtF(T.Position / 100);
end;

procedure TMainForm.ApplySlider(K: TSliderKind);
var
  C: TPzChain;
  Neutral: string;
begin
  case K of
    skFill: SetLastFilter('fill', [SV(Sliders[skFill])]);
    skTilt: SetLastFilter('tilt', [SV(Sliders[skTilt]), FmtF(0)]);
    skTFill, skTHigh, skTShadow, skTTemp:
    begin
      Neutral := '00000000';
      C := ParseChain(Cur.Filters);
      if (Length(C) > 0) and (C[High(C)].Name = 'finetune2') and
        (Length(C[High(C)].Args) > 3) then
        Neutral := C[High(C)].Args[3];
      SetLastFilter('finetune2', [SV(Sliders[skTFill]), SV(Sliders[skTHigh]),
        SV(Sliders[skTShadow]), Neutral, SV(Sliders[skTTemp])]);
    end;
    skBright, skContrast: SetLastFilter('pzbc',
        [SV(Sliders[skBright]), SV(Sliders[skContrast])]);
    skSharpen: SetLastFilter('unsharp2', [SV(Sliders[skSharpen])]);
    skSat: SetLastFilter('sat', [SV(Sliders[skSat])]);
    skBoost: SetLastFilter('Boost', [FmtF(Sliders[skBoost].Position / 100 * 12)]);
    skSoft: SetLastFilter('pzsoft', [SV(Sliders[skSoft])]);
    skVignette: SetLastFilter('pzvignette', [SV(Sliders[skVignette])]);
  end;
end;

procedure TMainForm.SliderChange(Sender: TObject);
var
  K: TSliderKind;
  Other: TSliderKind;
begin
  if FUpdatingUI or (Cur = nil) then
    Exit;
  K := TSliderKind(TTrackBar(Sender).Tag);
  { switching to a different filter kind: reset the other sliders so the UI
    shows what the new last step contains }
  FUpdatingUI := True;
  for Other := Low(TSliderKind) to High(TSliderKind) do
    if Other <> K then
      case K of
        skTFill, skTHigh, skTShadow, skTTemp:
          if not (Other in [skTFill, skTHigh, skTShadow, skTTemp]) then
            Sliders[Other].Position := 0;
        skBright, skContrast:
          if not (Other in [skBright, skContrast]) then Sliders[Other].Position := 0;
        else
          Sliders[Other].Position := 0;
      end;
  FUpdatingUI := False;
  ApplySlider(K);
end;

procedure TMainForm.EffectClick(Sender: TObject);
begin
  AppendFilter(TButton(Sender).Hint, []);
end;

procedure TMainForm.CropClick(Sender: TObject);
begin
  if Cur = nil then
    Exit;
  Viewer.Zoom100 := False;
  Viewer.SetMode(vmCrop);
  AspectChange(nil);
  BtnCropApply.Enabled := True;
  BtnCropCancel.Enabled := True;
end;

procedure TMainForm.AspectChange(Sender: TObject);
const
  A: array[0..7] of Double = (0, 4 / 3, 3 / 2, 16 / 9, 1, 5 / 4, 3 / 4, 2 / 3);
begin
  Viewer.CropAspect := A[Max(0, CmbAspect.ItemIndex)];
  if (Viewer.CropAspect > 0) and (Viewer.Bmp <> nil) and
    (Viewer.Bmp.Height > Viewer.Bmp.Width) and (Viewer.CropAspect > 1) then
    Viewer.CropAspect := 1 / Viewer.CropAspect; // portrait photo: rotate the ratio
end;

procedure TMainForm.CropApplyClick(Sender: TObject);
var
  L, T, R, B, x0, y0, x1, y1: Double;
  q: Integer;

  procedure Unrot(xd, yd: Double; out xs, ys: Double);
  begin
    case q of
      1: begin
        xs := yd;
        ys := 1 - xd;
      end;
      2: begin
        xs := 1 - xd;
        ys := 1 - yd;
      end;
      3: begin
        xs := 1 - yd;
        ys := xd;
      end;
      else
      begin
        xs := xd;
        ys := yd;
      end;
    end;
  end;

begin
  if (Cur <> nil) and Viewer.CropRectNorm(L, T, R, B) then
  begin
    { the viewer shows the photo after rotation; crop64 lives before it }
    q := ((Cur.Rotate mod 4) + 4) mod 4;
    Unrot(L, T, x0, y0);
    Unrot(R, B, x1, y1);
    AppendFilter('crop64', [Crop64Encode(Min(x0, x1), Min(y0, y1),
      Max(x0, x1), Max(y0, y1))]);
  end;
  CropCancelClick(nil);
end;

procedure TMainForm.CropCancelClick(Sender: TObject);
begin
  Viewer.SetMode(vmNormal);
  BtnCropApply.Enabled := False;
  BtnCropCancel.Enabled := False;
end;

procedure TMainForm.PickClick(Sender: TObject);
begin
  Viewer.SetMode(vmPick);
end;

procedure TMainForm.ViewerPick(Sender: TObject; NX, NY: Double);
var
  E: TViewEntry;
  Img: Tpz_image;
  C: TPzChain;
  x, y, i, j, n: Integer;
  sr, sg, sb: Int64;
  px: LongWord;
  Hex: string;
begin
  Viewer.SetMode(vmNormal);
  E := CacheFind(Cur, 1);
  if E = nil then
    Exit;
  { sample the photo as it looks before the current tuning step }
  C := ParseChain(Cur.Filters);
  if (Length(C) > 0) and (C[High(C)].Name = 'finetune2') then
    SetLength(C, Length(C) - 1);
  if pz_copy(@E.Img, @Img) <> 0 then
    Exit;
  RenderChain(Img, C, Cur.Rotate);
  x := EnsureRange(Round(NX * Img.w), 0, Img.w - 1);
  y := EnsureRange(Round(NY * Img.h), 0, Img.h - 1);
  sr := 0;
  sg := 0;
  sb := 0;
  n := 0;
  for j := Max(0, y - 3) to Min(Img.h - 1, y + 3) do
    for i := Max(0, x - 3) to Min(Img.w - 1, x + 3) do
    begin
      px := Img.px[j * Img.w + i];
      Inc(sb, px and $FF);
      Inc(sg, (px shr 8) and $FF);
      Inc(sr, (px shr 16) and $FF);
      Inc(n);
    end;
  pz_free(@Img);
  if n = 0 then
    Exit;
  Hex := LowerCase(Format('ff%.2x%.2x%.2x', [sr div n, sg div n, sb div n]));
  C := ParseChain(Cur.Filters);
  if (Length(C) > 0) and (C[High(C)].Name = 'finetune2') and
    (Length(C[High(C)].Args) >= 5) then
  begin
    C[High(C)].Args[3] := Hex;
    Cur.Filters := ChainToString(C);
    EditsChanged(Cur);
  end
  else
    AppendFilter('finetune2', [FmtF(0), FmtF(0), FmtF(0), Hex, FmtF(0)]);
end;

procedure TMainForm.UndoClick(Sender: TObject);
var
  C, R: TPzChain;
  F: TPzFilter;
begin
  if Cur = nil then
    Exit;
  C := ParseChain(Cur.Filters);
  if Length(C) = 0 then
    Exit;
  F := ChainPop(C);
  R := ParseChain(Cur.Redo);
  SetLength(R, Length(R) + 1);
  Move(R[0], R[1], (Length(R) - 1) * SizeOf(TPzFilter));
  FillChar(R[0], SizeOf(TPzFilter), 0);
  R[0] := F;
  Cur.Filters := ChainToString(C);
  Cur.Redo := ChainToString(R);
  EditsChanged(Cur);
  LoadSlidersFromChain;
end;

procedure TMainForm.RedoClick(Sender: TObject);
var
  C, R: TPzChain;
  i: Integer;
begin
  if Cur = nil then
    Exit;
  R := ParseChain(Cur.Redo);
  if Length(R) = 0 then
    Exit;
  C := ParseChain(Cur.Filters);
  ChainAppend(C, R[0]);
  for i := 0 to High(R) - 1 do
    R[i] := R[i + 1];
  SetLength(R, Length(R) - 1);
  Cur.Filters := ChainToString(C);
  Cur.Redo := ChainToString(R);
  EditsChanged(Cur);
  LoadSlidersFromChain;
end;

procedure TMainForm.UndoAllClick(Sender: TObject);
begin
  if (Cur = nil) or (Cur.Filters = '') then
    Exit;
  Cur.Redo := Cur.Filters + Cur.Redo;
  Cur.Filters := '';
  EditsChanged(Cur);
  LoadSlidersFromChain;
end;

procedure TMainForm.ToggleStar(P: TPzPhoto);
begin
  if P = nil then
    Exit;
  P.Folder.EnsureIni;
  P.Star := not P.Star;
  EditsChanged(P);
  if P = Cur then
    if P.Star then BtnStar.Caption := '★ Star'
    else
      BtnStar.Caption := '☆ Star';
  Strip.Invalidate;
end;

procedure TMainForm.RotatePhoto(P: TPzPhoto; Delta: Integer);
begin
  if P = nil then
    Exit;
  P.Folder.EnsureIni;
  P.Rotate := ((P.Rotate + Delta) mod 4 + 4) mod 4;
  EditsChanged(P);
end;

procedure TMainForm.BackClick(Sender: TObject);
begin
  SetEditMode(False);
end;

procedure TMainForm.StarClick(Sender: TObject);
begin
  ToggleStar(Cur);
end;

procedure TMainForm.RotLClick(Sender: TObject);
begin
  RotatePhoto(Cur, -1);
end;

procedure TMainForm.RotRClick(Sender: TObject);
begin
  RotatePhoto(Cur, 1);
end;

procedure TMainForm.ZoomClick(Sender: TObject);
begin
  if Cur = nil then
    Exit;
  Viewer.Zoom100 := not Viewer.Zoom100;
  if Viewer.Zoom100 and (CacheFind(Cur, 3) = nil) then
    Lib.RequestView(Cur, 0, 0, RawFlags or PZ_RAW_FULL, -1, True);
  RenderCurrent;
end;

type
  TExportThread = class(TThread)
    Paths, Edits, Dests: TStringList;
    Rots: array of Integer;
    Flags: Integer;
    Done: Integer;
    procedure Execute; override;
    destructor Destroy; override;
  end;

procedure TExportThread.Execute;
var
  i: Integer;
  Img: Tpz_image;
  M: Tpz_meta;
begin
  for i := 0 to Paths.Count - 1 do
  begin
    if Terminated then
      Break;
    if pz_load(PAnsiChar(Paths[i]), 0, 0, Flags, @Img, @M) >= 0 then
    begin
      RenderChain(Img, ParseChain(Edits[i]), Rots[i]);
      pz_save_jpeg(PAnsiChar(Dests[i]), @Img, 92);
      pz_free(@Img);
    end;
    Done := i + 1;
  end;
end;

destructor TExportThread.Destroy;
begin
  Paths.Free;
  Edits.Free;
  Dests.Free;
  inherited Destroy;
end;

procedure TMainForm.ExportPhotos(L: TList; const Dir: string);
var
  T: TExportThread;
  i: Integer;
  P: TPzPhoto;
begin
  T := TExportThread.Create(True);
  T.FreeOnTerminate := True;
  T.Paths := TStringList.Create;
  T.Edits := TStringList.Create;
  T.Dests := TStringList.Create;
  SetLength(T.Rots, L.Count);
  T.Flags := RawFlags or PZ_RAW_FULL;
  for i := 0 to L.Count - 1 do
  begin
    P := TPzPhoto(L[i]);
    P.Folder.EnsureIni;
    T.Paths.Add(P.Path);
    T.Edits.Add(P.Filters);
    T.Rots[i] := P.Rotate;
    T.Dests.Add(IncludeTrailingPathDelimiter(Dir) + ChangeFileExt(P.Name, '.jpg'));
  end;
  T.Start;
  Status.SimpleText := Format('Exporting %d photo(s) to %s …', [L.Count, Dir]);
end;

procedure TMainForm.ExportClick(Sender: TObject);
var
  Dir: string;
  L: TList;
begin
  if not SelectDirectory('Export to folder', GetEnvironmentVariable('HOME'), Dir) then
    Exit;
  L := TList.Create;
  try
    if FEditMode then
      L.Add(Cur)
    else
      Grid.SelectionList(L);
    if L.Count > 0 then
      ExportPhotos(L, Dir);
  finally
    L.Free;
  end;
end;

{ ---------------- keyboard, status, close ---------------- }

procedure TMainForm.FormKeyDown(Sender: TObject; var Key: Word; Shift: TShiftState);
var
  P: TPzPhoto;
begin
  if (ActiveControl is TEdit) then
    Exit;
  if FEditMode then
    P := Cur
  else
    P := Grid.Selected;
  if (ssCtrl in Shift) and (Key = VK_8) then
    ToggleStar(P)
  else if (ssCtrl in Shift) and (Key = VK_OEM_6) then // ]
    RotatePhoto(P, 1)
  else if (ssCtrl in Shift) and (Key = VK_OEM_4) then // [
    RotatePhoto(P, -1)
  else if FEditMode then
  begin
    if (ssCtrl in Shift) and (Key = VK_Z) then UndoClick(nil)
    else if (ssCtrl in Shift) and (Key = VK_Y) then RedoClick(nil)
    else if Key in [VK_RIGHT, VK_NEXT, VK_SPACE] then Navigate(1)
    else if Key in [VK_LEFT, VK_PRIOR, VK_BACK] then Navigate(-1)
    else if Key = VK_ESCAPE then
    begin
      if Viewer.Mode <> vmNormal then CropCancelClick(nil)
      else
        SetEditMode(False);
    end
    else if (Key = VK_RETURN) and (Viewer.Mode = vmCrop) then CropApplyClick(nil)
    else if Key = VK_1 then ZoomClick(nil)
    else
      Exit;
  end
  else
    Exit;
  Key := 0;
end;

procedure TMainForm.UpdateStatus;
var
  P: TPzPhoto;
  n, i: Integer;
begin
  if FEditMode then P := Cur
  else
    P := Grid.Selected;
  n := 0;
  for i := 0 to Lib.Folders.Count - 1 do
    Inc(n, TPzFolder(Lib.Folders[i]).Count);
  if P <> nil then
    Status.SimpleText := Format(
      '%d folders, %d photos    |    %s   %dx%d   %s   %s   %.1f MB',
      [Lib.Folders.Count, n, P.Name, P.W, P.H, FormatTaken(P.Taken),
      P.Camera, P.Size / 1048576])
  else
    Status.SimpleText := Format('%d folders, %d photos', [Lib.Folders.Count, n]);
end;

procedure TMainForm.TmrStatusTimer(Sender: TObject);
var
  S: string;
begin
  S := '';
  if Lib.ScanBusy then
    S := 'Scanning folders… ';
  if (Lib.GenTotal > 0) and (Lib.GenDone < Lib.GenTotal) then
    S := S + Format('Building thumbnails %d / %d', [Lib.GenDone, Lib.GenTotal]);
  LblStatus.Caption := S;
  if FTreeDirty and not Lib.ScanBusy then
    RebuildTree;
end;

procedure TMainForm.FormClose(Sender: TObject; var CloseAction: TCloseAction);
begin
  TmrStatus.Enabled := False;
  TmrIni.Enabled := False;
  FlushInis;
  Settings.WriteInteger('window', 'width', Width);
  Settings.WriteInteger('window', 'height', Height);
  Settings.WriteInteger('window', 'tree', Tree.Width);
  Settings.WriteInteger('view', 'thumbsize', TrkSize.Position);
  Settings.WriteBool('view', 'rawpreview', ChkRawPreview.Checked);
  Lib.Shutdown;
  Lib.Free;
  Lib := nil;
end;

{$I pzbench.inc}

end.
