{ Pizzicato main window: library mode (folder tree + continuous grid) and
  edit mode (Picasa-style Basic Fixes / Tuning / Effects panel, viewer,
  filmstrip). Also hosts the --bench driver. }
unit mainform;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Forms, Controls, Graphics, StdCtrls, ExtCtrls, ComCtrls, Dialogs,
  LCLType, LCLIntf, IniFiles, Math, StrUtils, Menus, DateUtils, Clipbrd, LCLProc,
  Buttons, ImgList, gdk2,
  pzcorebind, pzini, pzrender, pzlibrary, pzviews, pzicons, pzai, md5;

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
    skSharpen, skSat, skBoost, skSoft, skVignette, skDenoise);

  { TMainForm }

  TMainForm = class(TForm)
  private
    Lib: TPzLibrary;
    Settings: TIniFile;
    { library mode }
    PnlTop: TPanel;
    BtnAdd: TBitBtn;
    EdSearch: TEdit;
    ChkStar: TSpeedButton;   // 'starred only' toggle
    ChkHidden: TSpeedButton; // 'show hidden photos' toggle
    ImgSearch, ImgSize: TImage;
    TabIcons: TImageList;
    FEffNames: TStringList;  // filter name of each effect button, by Tag
    { photo tray (bottom bar), as in Picasa }
    PnlBottom, PnlSummary, PnlBotRight: TPanel;
    LblSummary: TLabel;
    Tray: TPzTray;
    BtnPin, BtnClearSel: TSpeedButton;
    BtnTStar, BtnTRotL, BtnTRotR, BtnTTag, BtnTExport: TBitBtn;
    BtnShowProps, BtnShowTags, BtnEditInfo: TSpeedButton;
    { properties and tags (right panel) }
    PnlRight: TPanel;
    RightPages: TPageControl;
    TabProps, TabTags: TTabSheet;
    LstProps: TListBox;
    EdTag: TEdit;
    BtnAddTag, BtnRemoveTag: TBitBtn;
    LstTags: TListBox;
    FTagNames: TStringList;
    TreeIcons: TImageList;
    Held: TList;             // photos pinned in the tray
    FPropsQueued: Boolean;
    { context menus }
    PmPhoto, PmView, PmFolder: TPopupMenu;
    MiOpen, MiZoom, MiPastePhoto, MiPasteView: TMenuItem;
    MiHidePhoto, MiHideView: TMenuItem;
    MiFSelect, MiFHold, MiFExport, MiFDesc, MiFShow, MiFCopy, MiFRescan: TMenuItem;
    FMenuFolder: TPzFolder;
    FEditsClip: string;      // "Copy Edits": a filter chain
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
    BtnRedo, BtnUndoAll: TBitBtn;
    LblName: TLabel;
    PnlTools: TPanel;
    Pages: TPageControl;
    Viewer: TPzViewer;
    Strip: TPzStrip;
    Sliders: array[TSliderKind] of TTrackBar;
    CmbAspect: TComboBox;
    BtnCrop, BtnCropApply, BtnCropCancel, BtnPick: TBitBtn;
    Hist: TPzHistogram;
    PnlCaption: TPanel;
    EdCaption: TEdit;
    BtnStraighten: TSpeedButton;
    PnlCropOpts, PnlStraighten: TPanel;
    BtnEditTags: TSpeedButton;
    LblTagsIn: TLabel;
    QuickBtns: array[0..9] of TSpeedButton;
    FQuickTags: TStringList;
    BtnQuickCfg: TSpeedButton;
    Status: TStatusBar;
    TmrIni, TmrStatus: TTimer;
    TmrFull: TTimer;       // decodes full resolution once a photo has been looked at
    FFullReq: TPzPhoto;    // the photo whose full-resolution decode is queued
    { AI: one GPU worker, recent results, the viewer's progress line }
    AIWorker: TPzAIWorker;
    FAICache: TList;       // finished TPzAIJobs, newest last
    FAIDir: string;        // on-disk results, next to the thumbnail DB
    FAIMsg, FBaseInfo: string;
    PnlDenoise: TPanel;
    ChkDenoiseHQ: TCheckBox;
  private
    procedure AIDone(J: TPzAIJob);
    procedure AIProgress(ATag: Pointer; Done, Total: Integer);
    function AIKey(P: TPzPhoto; K: TPzAIKind; W, H: Integer): string;
    function AIFind(const Key: string): TPzAIJob;
    procedure SetViewerInfo;
    procedure DenoiseTileClick(Sender: TObject);
    procedure DenoiseOffClick(Sender: TObject);
    procedure DenoiseHQClick(Sender: TObject);
    procedure SetDenoise(AOn: Boolean; Amount: Double; HQ: Boolean);
  private
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
    procedure BuildBottomBar;
    function AddTile(AParent: TWinControl; const ACaption, AIcon, AHint: string;
      X, Y: Integer; H: TNotifyEvent): TSpeedButton;
    procedure StraightenClick(Sender: TObject);
    procedure ViewerZoomAt(Sender: TObject; NX, NY: Double);
    procedure ViewerUnzoom(Sender: TObject);
    procedure ViewerWheel(Sender: TObject; Delta: Integer);
    procedure MakeCursors;
    function AddMI(AMenu: TPopupMenu; const ACaption, AIcon, AKeys: string;
      H: TNotifyEvent): TMenuItem;
    procedure BuildMenus;
    procedure TargetPhotos(L: TList);
    procedure StarList(L: TList);
    procedure RotateList(L: TList; Delta: Integer);
    procedure GridContextPopup(Sender: TObject; MousePos: TPoint; var Handled: Boolean);
    procedure ViewerContextPopup(Sender: TObject; MousePos: TPoint;
      var Handled: Boolean);
    procedure TreeContextPopup(Sender: TObject; MousePos: TPoint; var Handled: Boolean);
    procedure PopupFolderMenu;
    procedure MOpenClick(Sender: TObject);
    procedure MDefaultAppClick(Sender: TObject);
    procedure MStarClick(Sender: TObject);
    procedure MHideClick(Sender: TObject);
    procedure MDeleteClick(Sender: TObject);
    procedure HiddenChange(Sender: TObject);
    procedure SetHideCaption(Mi: TMenuItem);
    function ShownPos(P: TPzPhoto): Integer;
    procedure DeletePhotos(L: TList);
    procedure MRotRClick(Sender: TObject);
    procedure MRotLClick(Sender: TObject);
    procedure MCopyEditsClick(Sender: TObject);
    procedure MPasteEditsClick(Sender: TObject);
    procedure MUndoAllClick(Sender: TObject);
    procedure MExportClick(Sender: TObject);
    procedure MCopyPathClick(Sender: TObject);
    procedure MShowFileClick(Sender: TObject);
    procedure MSelectAllClick(Sender: TObject);
    procedure MPropsClick(Sender: TObject);
    procedure MZoomClick(Sender: TObject);
    procedure MFSelectClick(Sender: TObject);
    procedure MFHoldClick(Sender: TObject);
    procedure MFExportClick(Sender: TObject);
    procedure MFDescClick(Sender: TObject);
    procedure MFShowClick(Sender: TObject);
    procedure MFCopyClick(Sender: TObject);
    procedure MFRescanClick(Sender: TObject);
    procedure MFExpandClick(Sender: TObject);
    procedure MFCollapseClick(Sender: TObject);
    procedure CaptionKeyPress(Sender: TObject; var Key: Char);
    procedure CaptionExit(Sender: TObject);
    procedure SaveCaption;
    procedure UpdateHistInfo;
    procedure SyncPanelButtons;
    procedure RightPagesChange(Sender: TObject);
    procedure QuickTagClick(Sender: TObject);
    procedure QuickCfgClick(Sender: TObject);
    procedure RefreshQuickTags;
    procedure SaveQuickTags;
    procedure LstTagsKeyDown(Sender: TObject; var Key: Word; Shift: TShiftState);
    procedure BuildRightPanel;
    procedure TrayPhotos(L: TList);
    procedure SelectionChanged;
    procedure UpdateProps;
    procedure QueueProps;
    procedure DoQueuedProps(Data: PtrInt);
    procedure UpdateTags;
    procedure ApplyTag(const ATag: string; AAdd: Boolean);
    procedure PinClick(Sender: TObject);
    procedure ClearSelClick(Sender: TObject);
    procedure TStarClick(Sender: TObject);
    procedure TRotLClick(Sender: TObject);
    procedure TRotRClick(Sender: TObject);
    procedure TTagClick(Sender: TObject);
    procedure ShowPanelClick(Sender: TObject);
    procedure AddTagClick(Sender: TObject);
    procedure RemoveTagClick(Sender: TObject);
    procedure EdTagKeyPress(Sender: TObject; var Key: Char);
    procedure TrayPick(Sender: TObject; P: TPzPhoto);
    procedure PropsDrawItem(Control: TWinControl; Index: Integer;
      ARect: TRect; State: TOwnerDrawState);
    function AddSlider(AParent: TWinControl; const ACaption: string;
      AMin, AMax: Integer; K: TSliderKind; var Y: Integer): TTrackBar;
    function AddButton(AParent: TWinControl; const ACaption: string;
      X, Y, W: Integer; Handler: TNotifyEvent; const AIcon: string = ''): TBitBtn;
    function AddIcon(AParent: TWinControl; const AIcon: string; X, Y: Integer): TImage;
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
    procedure TmrFullTimer(Sender: TObject);
    procedure RequestFull(P: TPzPhoto; Front: Boolean);
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
    procedure BenchAI(P: TPzPhoto);
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
  Held := TList.Create;
  FTagNames := TStringList.Create;
  FQuickTags := TStringList.Create;
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
  FAIDir := ExtractFileDir(DBPath) + '/ai';
  FAICache := TList.Create;
  pz_ai_set_cache_dir(PAnsiChar(ExtractFileDir(DBPath) + '/mnn'));
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
  FEffNames.Free;
  Held.Free;
  FTagNames.Free;
  FQuickTags.Free;
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
  { the properties/tags panel as it was left }
  case Settings.ReadInteger('view', 'rightpanel', 0) of
    1: BtnShowProps.Down := True;
    2: BtnShowTags.Down := True;
  end;
  PnlRight.Visible := BtnShowProps.Down or BtnShowTags.Down;
  if BtnShowTags.Down then
    RightPages.ActivePage := TabTags
  else
    RightPages.ActivePage := TabProps;
  SyncPanelButtons;
  SelectionChanged;
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

  BtnAdd := AddButton(PnlTop, 'Add Folder…', 8, 6, 124, @AddFolderClick, 'addfolder');
  ImgSearch := AddIcon(PnlTop, 'search', 144, 10);
  EdSearch := TEdit.Create(Self);
  EdSearch.Parent := PnlTop;
  EdSearch.SetBounds(168, 7, 220, 26);
  EdSearch.TextHint := 'Search folders, tags, file names';
  EdSearch.OnChange := @SearchChange;
  ChkStar := TSpeedButton.Create(Self);
  ChkStar.Parent := PnlTop;
  ChkStar.SetBounds(398, 6, 96, 28);
  ChkStar.Caption := 'Starred';
  ChkStar.Hint := 'Show starred photos only';
  ChkStar.ShowHint := True;
  ChkStar.GroupIndex := 1;
  ChkStar.AllowAllUp := True;
  ChkStar.Spacing := 4;
  PzSetGlyph(ChkStar, 'star');
  ChkStar.OnClick := @StarChange;
  ChkHidden := TSpeedButton.Create(Self);
  ChkHidden.Parent := PnlTop;
  ChkHidden.SetBounds(500, 6, 96, 28);
  ChkHidden.Caption := 'Hidden';
  ChkHidden.Hint := 'Show hidden photos too';
  ChkHidden.ShowHint := True;
  ChkHidden.GroupIndex := 2;
  ChkHidden.AllowAllUp := True;
  ChkHidden.Spacing := 4;
  PzSetGlyph(ChkHidden, 'unhide');
  ChkHidden.Down := Settings.ReadBool('view', 'showhidden', False);
  ChkHidden.OnClick := @HiddenChange;
  ChkRawPreview := TCheckBox.Create(Self);
  ChkRawPreview.Parent := PnlTop;
  ChkRawPreview.SetBounds(608, 10, 200, 22);
  ChkRawPreview.Caption := 'RAW: use camera preview';
  ChkRawPreview.Font.Color := clPzHeader;
  ChkRawPreview.Checked := Settings.ReadBool('view', 'rawpreview', True);
  ChkRawPreview.OnChange := @RawModeChange;
  ImgSize := AddIcon(PnlTop, 'thumbsize', 818, 10);
  ImgSize.Hint := 'Thumbnail size';
  ImgSize.ShowHint := True;
  L := nil;
  TrkSize := TTrackBar.Create(Self);
  TrkSize.Parent := PnlTop;
  TrkSize.SetBounds(842, 4, 180, 32);
  TrkSize.Min := 64;
  TrkSize.Max := 320;
  TrkSize.Frequency := 32;
  TrkSize.Position := Settings.ReadInteger('view', 'thumbsize', 160);
  TrkSize.OnChange := @SizeChange;
  TrkSize.TabStop := False;
  LblStatus := TLabel.Create(Self);
  LblStatus.Parent := PnlTop;
  LblStatus.SetBounds(1038, 12, 500, 20);
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
  TreeIcons := TImageList.Create(Self);
  TreeIcons.Width := Max(16, PzIconSize - 4);
  TreeIcons.Height := TreeIcons.Width;
  PzAddToImageList(TreeIcons, 'calendar'); // 0: a year
  PzAddToImageList(TreeIcons, 'folder');   // 1: an album
  Tree.Images := TreeIcons;

  Splitter := TSplitter.Create(Self);
  Splitter.Parent := PnlLibrary;
  Splitter.Align := alLeft;
  Splitter.Left := Tree.Width + 1;

  Grid := TPzGrid.Create(Self);
  Grid.Parent := PnlLibrary;
  Grid.Align := alClient;
  Grid.ThumbSize := TrkSize.Position;
  Grid.ShowHidden := ChkHidden.Down;
  Grid.OnOpen := @GridOpen;
  Grid.OnSelect := @GridSelect;
  Grid.OnTopFolder := @GridTopFolder;
  Grid.SetFolderIcon(PzIconBitmap('folder', 2 * PzIconSize - 8));

  { ---- edit mode ---- }
  PnlEdit := TPanel.Create(Self);
  PnlEdit.Parent := Self;
  PnlEdit.Align := alClient;
  PnlEdit.BevelOuter := bvNone;
  PnlEdit.Visible := False;
  BuildEditPanel;
  BuildBottomBar;
  BuildRightPanel;
  MakeCursors;
  BuildMenus;
  Grid.OnContextPopup := @GridContextPopup;
  Viewer.OnContextPopup := @ViewerContextPopup;
  Tree.OnContextPopup := @TreeContextPopup;

  TmrFull := TTimer.Create(Self);
  TmrFull.Enabled := False;
  TmrFull.Interval := 500;
  TmrFull.OnTimer := @TmrFullTimer;
  TmrIni := TTimer.Create(Self);
  TmrIni.Enabled := False;
  TmrIni.Interval := 1500;
  TmrIni.OnTimer := @TmrIniTimer;
  TmrStatus := TTimer.Create(Self);
  TmrStatus.Interval := 500;
  TmrStatus.OnTimer := @TmrStatusTimer;
end;

function TMainForm.AddButton(AParent: TWinControl; const ACaption: string;
  X, Y, W: Integer; Handler: TNotifyEvent; const AIcon: string): TBitBtn;
begin
  Result := TBitBtn.Create(Self);
  Result.Parent := AParent;
  Result.SetBounds(X, Y, W, 28);
  Result.Caption := ACaption;
  Result.OnClick := Handler;
  Result.TabStop := False;
  if AIcon <> '' then
  begin
    PzSetGlyph(Result, AIcon);
    Result.Spacing := 4;
    Result.Margin := IfThen(ACaption = '', -1, 4);
  end;
end;

function TMainForm.AddIcon(AParent: TWinControl; const AIcon: string;
  X, Y: Integer): TImage;
var
  Bmp: TBitmap;
begin
  Result := TImage.Create(Self);
  Result.Parent := AParent;
  Result.SetBounds(X, Y, PzIconSize, PzIconSize);
  Result.Transparent := True;
  Bmp := PzIconBitmap(AIcon, PzIconSize);
  if Bmp <> nil then
    try
      Result.Picture.Assign(Bmp);
    finally
      Bmp.Free;
    end;
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
  B: TBitBtn;
  P: TPanel;
  BtnCropTile: TSpeedButton;

  procedure EffTile(AParent: TWinControl; const Cap, Name, Tip: string; X, YY: Integer);
  var
    BB: TSpeedButton;
  begin
    BB := AddTile(AParent, Cap, Name, Tip, X, YY, @EffectClick);
    BB.Tag := FEffNames.Add(Name);
  end;

  procedure Eff(const Cap, Name, Tip: string; X, YY, WW: Integer);
  var
    BB: TBitBtn;
  begin
    { the filter name doubles as the icon name }
    BB := AddButton(TS, Cap, X, YY, WW, @EffectClick, Name);
    BB.Tag := FEffNames.Add(Name);
    BB.Hint := Tip;
  end;

  procedure TabIcon(const AIcon: string);
  begin
    TS.ImageIndex := PzAddToImageList(TabIcons, AIcon);
  end;

begin
  FEffNames := TStringList.Create;
  PnlEditTop := TPanel.Create(Self);
  PnlEditTop.Parent := PnlEdit;
  PnlEditTop.Align := alTop;
  PnlEditTop.Height := 40;
  PnlEditTop.BevelOuter := bvNone;
  PnlEditTop.Color := TColor($303030);
  BtnBack := AddButton(PnlEditTop, 'Library', 8, 6, 100, @BackClick, 'library');
  BtnBack.Hint := 'Back to the library (Esc)';
  BtnStar := AddButton(PnlEditTop, 'Star', 114, 6, 96, @StarClick, 'star');
  BtnStar.Hint := 'Star this photo (Ctrl+8)';
  BtnRotL := AddButton(PnlEditTop, '', 216, 6, 34, @RotLClick, 'rotleft');
  BtnRotL.Hint := 'Rotate counter-clockwise (Ctrl+[)';
  BtnRotR := AddButton(PnlEditTop, '', 254, 6, 34, @RotRClick, 'rotright');
  BtnRotR.Hint := 'Rotate clockwise (Ctrl+])';
  BtnZoom := AddButton(PnlEditTop, '1:1', 296, 6, 64, @ZoomClick, 'zoom100');
  BtnZoom.Hint := 'Actual pixels (1)';
  BtnExport := AddButton(PnlEditTop, 'Export…', 366, 6, 100, @ExportClick, 'export');
  BtnExport.Hint := 'Save an edited copy as JPEG';
  LblName := TLabel.Create(Self);
  LblName.Parent := PnlEditTop;
  LblName.SetBounds(482, 12, 900, 20);
  LblName.Font.Color := clPzHeader;

  PnlTools := TPanel.Create(Self);
  PnlTools.Parent := PnlEdit;
  PnlTools.Align := alLeft;
  PnlTools.Width := 262;
  PnlTools.BevelOuter := bvNone;
  { Picasa's "Histogram & Camera Information" box under the tools }
  Hist := TPzHistogram.Create(Self);
  Hist.Parent := PnlTools;
  Hist.Align := alBottom;
  Hist.Height := 166;

  P := TPanel.Create(Self);
  P.Parent := PnlTools;
  P.Align := alTop;
  P.Height := 38;
  P.BevelOuter := bvNone;
  P.ParentColor := True;
  BtnUndo := AddButton(P, 'Undo', 6, 4, 80, @UndoClick, 'undo');
  BtnUndo.Hint := 'Undo the last edit (Ctrl+Z)';
  BtnRedo := AddButton(P, 'Redo', 90, 4, 80, @RedoClick, 'redo');
  BtnRedo.Hint := 'Redo (Ctrl+Y)';
  BtnUndoAll := AddButton(P, 'All', 174, 4, 82, @UndoAllClick, 'undoall');
  BtnUndoAll.Hint := 'Undo all edits of this photo';
  PnlEdit.ShowHint := True;
  TabIcons := TImageList.Create(Self);
  TabIcons.Width := PzIconSize;
  TabIcons.Height := PzIconSize;

  Pages := TPageControl.Create(Self);
  Pages.Parent := PnlTools;
  Pages.Align := alClient;
  Pages.TabStop := False;
  Pages.Images := TabIcons;

  { Basic fixes }
  TS := Pages.AddTabSheet;
  TS.Caption := 'Basic';
  TabIcon('tab_basic');
  { Picasa's Basic Fixes: a grid of tiles, then the options of the active tool }
  P := TPanel.Create(Self);
  P.Parent := TS;
  P.Align := alTop;
  P.Height := 156;
  P.BevelOuter := bvNone;
  P.ParentColor := True;
  BtnCropTile := AddTile(P, 'Crop', 'crop', 'Crop the photo', 4, 4, @CropClick);
  BtnStraighten := AddTile(P, 'Straighten', 'straighten', 'Level a tilted horizon',
    86, 4, @StraightenClick);
  BtnStraighten.GroupIndex := 7;
  BtnStraighten.AllowAllUp := True;
  EffTile(P, 'Feeling Lucky', 'enhance',
    'I''m Feeling Lucky: automatic contrast and colour', 168, 4);
  EffTile(P, 'Auto Contrast', 'autolight', 'Stretch the brightness range', 4, 80);
  EffTile(P, 'Auto Color', 'autocolor', 'Remove a colour cast', 86, 80);
  AddTile(P, 'AI Denoise', 'denoise', 'Remove noise with a neural network (GPU)',
    168, 80, @DenoiseTileClick);

  PnlCropOpts := TPanel.Create(Self);
  PnlCropOpts.Parent := TS;
  PnlCropOpts.Align := alTop;
  PnlCropOpts.Top := 1000;
  PnlCropOpts.Height := 76;
  PnlCropOpts.BevelOuter := bvNone;
  PnlCropOpts.ParentColor := True;
  PnlCropOpts.Visible := False;
  CmbAspect := TComboBox.Create(Self);
  CmbAspect.Parent := PnlCropOpts;
  CmbAspect.SetBounds(8, 4, 236, 28);
  CmbAspect.Style := csDropDownList;
  CmbAspect.Items.CommaText :=
    '"Free (drag on the photo)","4:3","3:2","16:9","1:1","5:4","3:4","2:3"';
  CmbAspect.ItemIndex := 0;
  CmbAspect.OnChange := @AspectChange;
  CmbAspect.TabStop := False;
  BtnCropApply := AddButton(PnlCropOpts, 'Apply', 8, 40, 112, @CropApplyClick, 'apply');
  BtnCropApply.Hint := 'Apply the crop (Enter)';
  BtnCropCancel := AddButton(PnlCropOpts, 'Cancel', 128, 40, 116,
    @CropCancelClick, 'cancel');
  BtnCrop := BtnCropApply; // kept for older code paths

  PnlDenoise := TPanel.Create(Self);
  PnlDenoise.Parent := TS;
  PnlDenoise.Align := alTop;
  PnlDenoise.Top := 1050;
  PnlDenoise.Height := 92;
  PnlDenoise.BevelOuter := bvNone;
  PnlDenoise.ParentColor := True;
  PnlDenoise.Visible := False;
  Y := 4;
  AddSlider(PnlDenoise, 'AI Denoise strength', 0, 100, skDenoise, Y);
  ChkDenoiseHQ := TCheckBox.Create(Self);
  ChkDenoiseHQ.Parent := PnlDenoise;
  ChkDenoiseHQ.SetBounds(10, Y - 2, 140, 24);
  ChkDenoiseHQ.Caption := 'High quality';
  ChkDenoiseHQ.Hint := 'SCUNet instead of NAFNet: a little better, about 3x slower';
  ChkDenoiseHQ.ShowHint := True;
  ChkDenoiseHQ.Font.Color := clPzHeader;
  ChkDenoiseHQ.OnChange := @DenoiseHQClick;
  with AddButton(PnlDenoise, 'Remove', 150, Y - 2, 94, @DenoiseOffClick, 'cancel') do
    Hint := 'Take the AI denoise off';

  PnlStraighten := TPanel.Create(Self);
  PnlStraighten.Parent := TS;
  PnlStraighten.Align := alTop;
  PnlStraighten.Top := 1100;
  PnlStraighten.Height := 62;
  PnlStraighten.BevelOuter := bvNone;
  PnlStraighten.ParentColor := True;
  PnlStraighten.Visible := False;
  Y := 4;
  AddSlider(PnlStraighten, 'Straighten (drag, the grid helps)', -100, 100, skTilt, Y);

  P := TPanel.Create(Self);
  P.Parent := TS;
  P.Align := alTop;
  P.Top := 1200;
  P.Height := 64;
  P.BevelOuter := bvNone;
  P.ParentColor := True;
  Y := 4;
  AddSlider(P, 'Fill Light', 0, 100, skFill, Y);

  { Tuning }
  TS := Pages.AddTabSheet;
  TS.Caption := 'Tuning';
  TabIcon('tab_tuning');
  Y := 8;
  AddSlider(TS, 'Fill Light', 0, 100, skTFill, Y);
  AddSlider(TS, 'Highlights', 0, 100, skTHigh, Y);
  AddSlider(TS, 'Shadows', 0, 100, skTShadow, Y);
  AddSlider(TS, 'Color Temperature', -100, 100, skTTemp, Y);
  BtnPick := AddButton(TS, 'Neutral Color Picker', 8, Y, 236, @PickClick, 'picker');
  BtnPick.Hint := 'Click something that should be grey or white';
  Inc(Y, 40);
  AddSlider(TS, 'Brightness', -100, 100, skBright, Y);
  AddSlider(TS, 'Contrast', -100, 100, skContrast, Y);

  { Effects }
  TS := Pages.AddTabSheet;
  TS.Caption := 'Effects';
  TabIcon('tab_effects');
  EffTile(TS, 'B && W', 'bw', 'Convert to black and white', 4, 4);
  EffTile(TS, 'Sepia', 'sepia', 'Old-photo brown tone', 86, 4);
  EffTile(TS, 'Warmify', 'warm', 'Warmer colours', 168, 4);
  Y := 84;
  AddSlider(TS, 'Sharpen', 0, 100, skSharpen, Y);
  AddSlider(TS, 'Saturation', 0, 100, skSat, Y);
  AddSlider(TS, 'Boost', 0, 100, skBoost, Y);
  AddSlider(TS, 'Soft Focus', 0, 100, skSoft, Y);
  AddSlider(TS, 'Vignette', 0, 100, skVignette, Y);


  Strip := TPzStrip.Create(Self);
  Strip.Parent := PnlEdit;
  Strip.Align := alBottom;
  Strip.Height := 68;
  Strip.OnPick := @StripPick;

  { Picasa's caption line under the photo }
  PnlCaption := TPanel.Create(Self);
  PnlCaption.Parent := PnlEdit;
  PnlCaption.Align := alBottom;
  PnlCaption.Height := 32;
  PnlCaption.Top := Strip.Top - 1;
  PnlCaption.BevelOuter := bvNone;
  PnlCaption.Color := TColor($1C1C1C);
  EdCaption := TEdit.Create(Self);
  EdCaption.Parent := PnlCaption;
  EdCaption.Align := alClient;
  EdCaption.BorderSpacing.Around := 3;
  EdCaption.Alignment := taCenter;
  EdCaption.TextHint := 'Make a caption!';
  EdCaption.OnKeyPress := @CaptionKeyPress;
  EdCaption.OnExit := @CaptionExit;

  Viewer := TPzViewer.Create(Self);
  Viewer.Parent := PnlEdit;
  Viewer.Align := alClient;
  Viewer.OnPick := @ViewerPick;
  Viewer.OnZoomAt := @ViewerZoomAt;
  Viewer.OnUnzoom := @ViewerUnzoom;
  Viewer.OnWheelNav := @ViewerWheel;
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
    jkProbe:
    begin
      if PnlRight.Visible then
        QueueProps;
      if FEditMode and (R.Photo = Cur) then
        UpdateHistInfo;
    end;
  end;
  if (R.Kind = jkThumb) and (Tray.Photos.IndexOf(R.Photo) >= 0) then
    Tray.Invalidate;
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
        YNode.ImageIndex := 0;
        YNode.SelectedIndex := 0;
        LastYear := Year;
      end;
      N := Tree.Items.AddChildObject(YNode, F.Name + '  (' + IntToStr(F.Count) + ')', F);
      N.ImageIndex := 1;
      N.SelectedIndex := 1;
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
  SelectionChanged;
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
  Grid.StarOnly := ChkStar.Down;
end;

procedure TMainForm.HiddenChange(Sender: TObject);
begin
  Grid.ShowHidden := ChkHidden.Down;
  if FEditMode then
    Strip.Invalidate;
end;

procedure TMainForm.RawModeChange(Sender: TObject);
var
  i: Integer;
begin
  for i := 0 to Cache.Count - 1 do
    TViewEntry(Cache[i]).Free;
  Cache.Clear;
  FFullReq := nil;
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
  { the properties/tags panel follows into the editor }
  if AOn then
    PnlRight.Parent := PnlEdit
  else
    PnlRight.Parent := PnlLibrary;
  SyncPanelButtons;
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
  SelectionChanged;
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
  i, Oldest, nFull: Integer;
begin
  { full-resolution images are 50-100 MB each: keep the current one and one more }
  repeat
    nFull := 0;
    Oldest := -1;
    for i := 0 to Cache.Count - 1 do
      if TViewEntry(Cache[i]).Level = 3 then
      begin
        Inc(nFull);
        if (TViewEntry(Cache[i]).Photo <> Cur) and ((Oldest < 0) or
          (TViewEntry(Cache[i]).Stamp < TViewEntry(Cache[Oldest]).Stamp)) then
          Oldest := i;
      end;
    if (nFull <= 2) or (Oldest < 0) then
      Break;
    TViewEntry(Cache[Oldest]).Free;
    Cache.Delete(Oldest);
  until False;
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
  { replace lower levels of the same photo -- but keep the screen-size image
    next to a full-resolution one: the fitted view renders from it, fast }
  for i := Cache.Count - 1 downto 0 do
    if (TViewEntry(Cache[i]).Photo = R.Photo) and (TViewEntry(Cache[i]).Level < Lvl) and
      not ((Lvl = 3) and (TViewEntry(Cache[i]).Level = 2)) then
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
    SaveCaption;
  if (Cur <> nil) and (Cur <> P) then
    Viewer.SetMode(vmNormal);
  if Cur <> P then
  begin
    FFullReq := nil;
    if AIWorker <> nil then
      AIWorker.CancelOthers(P);
  end;
  Cur := P;
  Inc(ViewToken);
  TmrFull.Enabled := False;
  TmrFull.Enabled := True;
  FCurLevel := 0;
  FOpenT0 := NowSeconds;
  FFirstFullMs := -1;
  Viewer.Zoom100 := False;
  PnlCropOpts.Visible := False;
  if BtnStraighten.Down then
  begin
    BtnStraighten.Down := False;
    StraightenClick(nil);
  end;

  P.Folder.EnsureIni;
  LblName.Caption := Format('%s    %s', [P.Name, P.Folder.Path]);
  if P.Star then BtnStar.Caption := 'Starred'
  else
    BtnStar.Caption := 'Star';
  Strip.SetCurrent(P);
  LoadSlidersFromChain;
  EdCaption.Text := P.Caption;
  Hist.Clear;
  Lib.RequestProbe(P);
  UpdateHistInfo;
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
  SelectionChanged;
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
  T0, s, f: Double;
  W, H: Integer;
  Info: string;
  HistData: Tpz_hist;
  DAmt: Double;
  DKind: TPzAIKind;
  DKey, DWhy: string;
  DJob: TPzAIJob;
begin
  if Cur = nil then
    Exit;
  if Viewer.Zoom100 then
    E := CacheFind(Cur, 3)
  else
    E := CacheFind(Cur, 2);
  { the fitted view: the screen-size image when there is one }
  if (E <> nil) and (E.Level = 3) and not Viewer.Zoom100 then
    for W := 0 to Cache.Count - 1 do
      if (TViewEntry(Cache[W]).Photo = Cur) and (TViewEntry(Cache[W]).Level = 2) then
        E := TViewEntry(Cache[W]);
  if E = nil then
    E := CacheFind(Cur, 1);
  if E = nil then
    Exit;
  T0 := NowSeconds;
  if pz_copy(@E.Img, @Img) <> 0 then
    Exit;
  { AI denoise, the chain's first step: blend in the denoised base image,
    or queue it on the GPU worker and show the photo as it is meanwhile }
  FAIMsg := '';
  if DenoiseOf(Cur.Filters, DAmt, DKind) and (E.Level >= 2) then
  begin
    DKey := AIKey(Cur, DKind, E.Img.w, E.Img.h);
    DJob := AIFind(DKey);
    if DJob <> nil then
      PzMix(Img, DJob.Img, DAmt)
    else if PzAIReady(DKind, DWhy) then
    begin
      if AIWorker = nil then
      begin
        AIWorker := TPzAIWorker.Create;
        AIWorker.OnDone := @AIDone;
        AIWorker.OnProgress := @AIProgress;
      end;
      if not AIWorker.Pending(DKey) then
      begin
        DJob := TPzAIJob.Create;
        DJob.Kind := DKind;
        DJob.Key := DKey;
        DJob.Tag := Cur;
        DJob.CachePath := FAIDir + '/' + MD5Print(MD5String(DKey)) + '.jpg';
        pz_copy(@E.Img, @DJob.Img);
        AIWorker.Submit(DJob);
      end;
      FAIMsg := Format('  ·  %s…', [PZ_AI_NAMES[DKind]]);
    end
    else
      FAIMsg := '  ·  AI denoise unavailable';
  end;
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
  pz_histogram(@Img, HistData);
  Hist.SetHistogram(HistData);
  if Viewer.Zoom100 then
  begin
    { until the full-resolution decode is in, show the screen-size image
      enlarged to the photo's real size, so 1:1 opens at once, in place }
    f := 1;
    if (E.Level < 3) and (Max(E.Img.w, E.Img.h) > 0) then
      f := Max(1.0, Max(Cur.W, Cur.H) / Max(E.Img.w, E.Img.h));
    Viewer.SetZoomImage(Img, Round(Img.w * f), Round(Img.h * f)); // takes Img
  end
  else
  begin
    Viewer.SetImage(ImageToBitmap(Img));
    pz_free(@Img);
  end;
  FCurLevel := E.Level;
  FLastRenderMs := (NowSeconds - T0) * 1000;
  if (E.Level >= 2) and (FFirstFullMs < 0) then
    FFirstFullMs := (NowSeconds - FOpenT0) * 1000;
  case E.Level of
    1: Info := 'embedded preview';
    2: if Viewer.Zoom100 then Info := 'screen size, enlarged until full resolution is in'
      else
        Info := 'screen size';
    3: Info := 'full resolution';
  end;
  if Viewer.Zoom100 then
    Info := '1:1 (drag to move, click to fit) · ' + Info
  else
    Info := 'fit · ' + Info;
  FBaseInfo := Format('%dx%d  %s  ·  %s  ·  render %.0f ms',
    [Cur.W, Cur.H, Cur.Camera, Info, FLastRenderMs]);
  SetViewerInfo;
end;

procedure TMainForm.SetViewerInfo;
begin
  Viewer.Info := FBaseInfo + FAIMsg;
  Viewer.Invalidate;
end;

{ ---------------- AI ---------------- }

{ what an AI result is of: the file's version, the model and the input size }
function TMainForm.AIKey(P: TPzPhoto; K: TPzAIKind; W, H: Integer): string;
begin
  Result := Format('%s|%d|%d|%s|%dx%d|%d', [P.Path, P.MTime, P.Size,
    ExtractFileName(PzAIModelFile(K)), W, H, RawFlags]);
end;

function TMainForm.AIFind(const Key: string): TPzAIJob;
var
  i: Integer;
begin
  for i := FAICache.Count - 1 downto 0 do
    if TPzAIJob(FAICache[i]).Key = Key then
      Exit(TPzAIJob(FAICache[i]));
  Result := nil;
end;

procedure TMainForm.AIDone(J: TPzAIJob);
var
  i, nBig: Integer;
begin
  if not J.OK then
  begin
    if (J.Tag = Pointer(Cur)) and (J.Error <> '') then
    begin
      FAIMsg := '  ·  ' + PZ_AI_NAMES[J.Kind] + ' failed: ' + J.Error;
      SetViewerInfo;
    end;
    J.Free;
    Exit;
  end;
  FAICache.Add(J);
  { keep a few results; full-resolution ones are large }
  repeat
    nBig := 0;
    for i := 0 to FAICache.Count - 1 do
      if TPzAIJob(FAICache[i]).Img.w * TPzAIJob(FAICache[i]).Img.h > 4000000 then
        Inc(nBig);
    if (FAICache.Count <= 6) and (nBig <= 2) then
      Break;
    for i := 0 to FAICache.Count - 1 do
      if (TPzAIJob(FAICache[i]) <> J) and ((FAICache.Count > 6) or
        (TPzAIJob(FAICache[i]).Img.w * TPzAIJob(FAICache[i]).Img.h > 4000000)) then
      begin
        TPzAIJob(FAICache[i]).Free;
        FAICache.Delete(i);
        Break;
      end;
  until False;
  if FBench then
    BLog(Format('    %s %dx%d: %.0f ms%s', [PZ_AI_NAMES[J.Kind],
      J.Img.w, J.Img.h, J.Seconds * 1000, IfThen(J.FromCache, ' (disk cache)', '')]));
  if J.Tag = Pointer(Cur) then
    QueueRender;
end;

procedure TMainForm.AIProgress(ATag: Pointer; Done, Total: Integer);
begin
  if (ATag <> Pointer(Cur)) or (Total <= 0) then
    Exit;
  FAIMsg := Format('  ·  AI working %d%%', [Done * 100 div Total]);
  SetViewerInfo;
end;

procedure TMainForm.SetDenoise(AOn: Boolean; Amount: Double; HQ: Boolean);
var
  C: TPzChain;
  i: Integer;
begin
  if Cur = nil then
    Exit;
  Cur.Folder.EnsureIni;
  C := ParseChain(Cur.Filters);
  { the denoise step always comes first: it works on the camera's image }
  if (Length(C) > 0) and (C[0].Name = 'pzdenoise') then
  begin
    for i := 0 to High(C) - 1 do
      C[i] := C[i + 1];
    SetLength(C, Length(C) - 1);
  end;
  if AOn then
  begin
    SetLength(C, Length(C) + 1);
    for i := High(C) downto 1 do
      C[i] := C[i - 1];
    C[0] := MakeFilter('pzdenoise', [FmtF(Amount), IntToStr(Ord(HQ))]);
  end;
  Cur.Filters := ChainToString(C);
  EditsChanged(Cur);
  LoadSlidersFromChain;
end;

procedure TMainForm.DenoiseTileClick(Sender: TObject);
var
  Why: string;
  A: Double;
  K: TPzAIKind;
begin
  if Cur = nil then
    Exit;
  if not PzAIReady(akDenoise, Why) then
  begin
    MessageDlg('AI Denoise', Why, mtInformation, [mbOK], 0);
    Exit;
  end;
  if not DenoiseOf(Cur.Filters, A, K) then
    SetDenoise(True, 0.8, False)
  else
    LoadSlidersFromChain;
end;

procedure TMainForm.DenoiseOffClick(Sender: TObject);
begin
  SetDenoise(False, 0, False);
end;

procedure TMainForm.DenoiseHQClick(Sender: TObject);
var
  A: Double;
  K: TPzAIKind;
  Why: string;
begin
  if FUpdatingUI or (Cur = nil) or not DenoiseOf(Cur.Filters, A, K) then
    Exit;
  if ChkDenoiseHQ.Checked and not PzAIReady(akDenoiseHQ, Why) then
  begin
    MessageDlg('AI Denoise', Why, mtInformation, [mbOK], 0);
    FUpdatingUI := True;
    ChkDenoiseHQ.Checked := False;
    FUpdatingUI := False;
    Exit;
  end;
  SetDenoise(True, A, ChkDenoiseHQ.Checked);
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
  DA: Double;
  DK: TPzAIKind;
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
    { the denoise step is first in the chain, not last }
    if PnlDenoise <> nil then
    begin
      PnlDenoise.Visible := (Cur <> nil) and DenoiseOf(Cur.Filters, DA, DK);
      if PnlDenoise.Visible then
      begin
        Sliders[skDenoise].Position := Round(DA * 100);
        ChkDenoiseHQ.Checked := DK = akDenoiseHQ;
      end;
    end;
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

procedure TMainForm.RequestFull(P: TPzPhoto; Front: Boolean);
begin
  if (P = nil) or (CacheFind(P, 3) <> nil) or (FFullReq = P) then
    Exit;
  FFullReq := P;
  Lib.RequestView(P, 0, 0, RawFlags or PZ_RAW_FULL, -1, Front);
end;

{ like Picasa: after half a second on a photo, its full resolution is
  decoded in the background, so 1:1 then opens at once }
procedure TMainForm.TmrFullTimer(Sender: TObject);
begin
  TmrFull.Enabled := False;
  if FEditMode and not FBench and (Cur <> nil) and (CacheFind(Cur, 2) <> nil) then
    RequestFull(Cur, False);
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
  if K = skDenoise then
  begin
    { the strength is a blend: no new step, and no recomputation }
    SetDenoise(True, Sliders[skDenoise].Position / 100, ChkDenoiseHQ.Checked);
    Exit;
  end;
  { switching to a different filter kind: reset the other sliders so the UI
    shows what the new last step contains }
  FUpdatingUI := True;
  for Other := Low(TSliderKind) to High(TSliderKind) do
    if (Other <> K) and (Other <> skDenoise) then
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
  AppendFilter(FEffNames[TControl(Sender).Tag], []);
end;

procedure TMainForm.CropClick(Sender: TObject);
begin
  if Cur = nil then
    Exit;
  Viewer.Zoom100 := False;
  Viewer.SetMode(vmCrop);
  AspectChange(nil);
  BtnStraighten.Down := False;
  StraightenClick(nil);
  PnlCropOpts.Top := 157;
  PnlCropOpts.Visible := True;

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
  PnlCropOpts.Visible := False;

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
    if P.Star then BtnStar.Caption := 'Starred'
    else
      BtnStar.Caption := 'Star';
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
  if not Viewer.Zoom100 and (Sender <> Viewer) then
    Viewer.SetZoomCenter(0.5, 0.5);
  Viewer.Zoom100 := not Viewer.Zoom100;
  if Viewer.Zoom100 then
    RequestFull(Cur, True);
  RenderCurrent;
end;

{ one photo of an export: decode at full resolution, the AI steps, the
  chain, an optional AI upscale, then a JPEG. Any thread. }
function ExportImage(const Path, Edits: string; Rot, Flags, Scale: Integer;
  const Dest: string; out W, H: Integer): Boolean;
var
  Img: Tpz_image;
  M: Tpz_meta;
begin
  Result := False;
  W := 0;
  H := 0;
  PzInit(Img);
  if pz_load(PAnsiChar(Path), 0, 0, Flags, @Img, @M) < 0 then
    Exit;
  try
    PzAIApplyChain(Img, Edits, nil);
    RenderChain(Img, ParseChain(Edits), Rot);
    if Scale > 1 then
      PzUpscale(Img, Scale);
    W := Img.w;
    H := Img.h;
    Result := pz_save_jpeg(PAnsiChar(Dest), @Img, 92) = 0;
  finally
    pz_free(@Img);
  end;
end;

type
  TExportThread = class(TThread)
    Paths, Edits, Dests: TStringList;
    Rots: array of Integer;
    Flags, Scale: Integer;
    Done: Integer;
    procedure Execute; override;
    destructor Destroy; override;
  end;

procedure TExportThread.Execute;
var
  i, W, H: Integer;
begin
  for i := 0 to Paths.Count - 1 do
  begin
    if Terminated then
      Break;
    ExportImage(Paths[i], Edits[i], Rots[i], Flags, Scale, Dests[i], W, H);
    Done := i + 1;
  end;
  PzAICloseThread;
end;

destructor TExportThread.Destroy;
begin
  Paths.Free;
  Edits.Free;
  Dests.Free;
  inherited Destroy;
end;

{ export size: the photo's own, or an AI upscale (when the model is there) }
function AskExportScale(out Scale: Integer): Boolean;
var
  F: TForm;
  R: TRadioGroup;
  B1, B2: TButton;
  Why: string;
begin
  Scale := 1;
  if not PzAIReady(akUpscale, Why) then
    Exit(True);
  F := TForm.CreateNew(nil);
  try
    F.Caption := 'Export';
    F.Width := 340;
    F.Height := 190;
    F.Position := poOwnerFormCenter;
    R := TRadioGroup.Create(F);
    R.Parent := F;
    R.SetBounds(10, 8, 320, 120);
    R.Caption := 'Size';
    R.Items.Add('Original size (after crop)');
    R.Items.Add('2x larger (AI upscale)');
    R.Items.Add('4x larger (AI upscale)');
    R.ItemIndex := 0;
    B1 := TButton.Create(F);
    B1.Parent := F;
    B1.SetBounds(150, 140, 84, 30);
    B1.Caption := 'Export';
    B1.ModalResult := mrOk;
    B1.Default := True;
    B2 := TButton.Create(F);
    B2.Parent := F;
    B2.SetBounds(244, 140, 84, 30);
    B2.Caption := 'Cancel';
    B2.ModalResult := mrCancel;
    B2.Cancel := True;
    Result := F.ShowModal = mrOk;
    if Result then
      Scale := 1 shl R.ItemIndex;
  finally
    F.Free;
  end;
end;

procedure TMainForm.ExportPhotos(L: TList; const Dir: string);
var
  T: TExportThread;
  i, Scale: Integer;
  P: TPzPhoto;
  Suffix: string;
begin
  if not AskExportScale(Scale) then
    Exit;
  Suffix := '';
  if Scale > 1 then
    Suffix := Format('_%dx', [Scale]);
  T := TExportThread.Create(True);
  T.Scale := Scale;
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
    T.Dests.Add(IncludeTrailingPathDelimiter(Dir) + ChangeFileExt(P.Name, '') +
      Suffix + '.jpg');
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
    TrayPhotos(L);
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
  { star, rotate and tag act on the whole tray, as Picasa's buttons do }
  if (ssCtrl in Shift) and (Key = VK_8) then
    TStarClick(nil)
  else if (ssCtrl in Shift) and (Key = VK_OEM_6) then // ]
    TRotRClick(nil)
  else if (ssCtrl in Shift) and (Key = VK_OEM_4) then // [
    TRotLClick(nil)
  else if (ssCtrl in Shift) and (Key = VK_T) then
    TTagClick(nil)
  else if (Key = VK_DELETE) and (Shift = []) and
    ((FEditMode and not (ActiveControl is TCustomListBox)) or
    (not FEditMode and (ActiveControl = Grid))) then
    MDeleteClick(nil)
  else if FEditMode then
  begin
    if (ssCtrl in Shift) and (Key = VK_Z) then UndoClick(nil)
    else if (ssCtrl in Shift) and (Key = VK_Y) then RedoClick(nil)
    else if Key in [VK_RIGHT, VK_NEXT, VK_SPACE] then Navigate(1)
    else if Key in [VK_LEFT, VK_PRIOR, VK_BACK] then Navigate(-1)
    else if Key = VK_ESCAPE then
    begin
      if Viewer.Zoom100 then ZoomClick(nil)
      else if Viewer.Mode <> vmNormal then CropCancelClick(nil)
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
var
  i: Integer;
begin
  TmrStatus.Enabled := False;
  TmrIni.Enabled := False;
  FlushInis;
  Settings.WriteInteger('window', 'width', Width);
  Settings.WriteInteger('window', 'height', Height);
  Settings.WriteInteger('window', 'tree', Tree.Width);
  Settings.WriteInteger('view', 'thumbsize', TrkSize.Position);
  Settings.WriteBool('view', 'rawpreview', ChkRawPreview.Checked);
  Settings.WriteBool('view', 'showhidden', ChkHidden.Down);
  if not PnlRight.Visible then
    Settings.WriteInteger('view', 'rightpanel', 0)
  else if RightPages.ActivePage = TabTags then
    Settings.WriteInteger('view', 'rightpanel', 2)
  else
    Settings.WriteInteger('view', 'rightpanel', 1);
  if AIWorker <> nil then
  begin
    AIWorker.Stop;
    FreeAndNil(AIWorker);
  end;
  for i := 0 to FAICache.Count - 1 do
    TPzAIJob(FAICache[i]).Free;
  FAICache.Clear;
  Lib.Shutdown;
  Lib.Free;
  Lib := nil;
end;

{ ---------------- photo tray, properties and tags ---------------- }

procedure TMainForm.BuildBottomBar;
var
  X: Integer;

  function TB(const ACap, AIcon, AHint: string; AW: Integer; H: TNotifyEvent): TBitBtn;
  begin
    Result := AddButton(PnlBottom, ACap, X, 30, AW, H, AIcon);
    Result.Height := 32;
    Result.Hint := AHint;
    Inc(X, AW + 6);
  end;

  function Toggle(AParent: TWinControl; const AIcon, AHint: string;
    AX, AGroup: Integer): TSpeedButton;
  begin
    Result := TSpeedButton.Create(Self);
    Result.Parent := AParent;
    Result.SetBounds(AX, 30, 40, 32);
    Result.Hint := AHint;
    Result.ShowHint := True;
    if AGroup > 0 then
    begin
      Result.GroupIndex := AGroup;
      Result.AllowAllUp := True;
    end;
    PzSetGlyph(Result, AIcon);
  end;

begin
  PnlBottom := TPanel.Create(Self);
  PnlBottom.Parent := Self; // shown under the library and the editor alike
  PnlBottom.Align := alBottom;
  PnlBottom.Height := 112;
  PnlBottom.BevelOuter := bvNone;
  PnlBottom.Color := TColor($2C2C2C);
  PnlBottom.ShowHint := True;

  { Picasa's blue strip: what the tray holds }
  PnlSummary := TPanel.Create(Self);
  PnlSummary.Parent := PnlBottom;
  PnlSummary.Align := alTop;
  PnlSummary.Height := 22;
  PnlSummary.BevelOuter := bvNone;
  PnlSummary.Color := TColor($B0782E);
  LblSummary := TLabel.Create(Self);
  LblSummary.Parent := PnlSummary;
  LblSummary.Align := alClient;
  LblSummary.Alignment := taCenter;
  LblSummary.Layout := tlCenter;
  LblSummary.Font.Color := clWhite;
  LblSummary.Font.Style := [fsBold];

  PnlBotRight := TPanel.Create(Self);
  PnlBotRight.Parent := PnlBottom;
  PnlBotRight.Align := alRight;
  PnlBotRight.Width := 330;
  PnlBotRight.BevelOuter := bvNone;
  PnlBotRight.ParentColor := True;
  { the thumbnail size slider lives here, as in Picasa }
  ImgSize.Parent := PnlBotRight;
  ImgSize.SetBounds(6, 14, PzIconSize, PzIconSize);
  TrkSize.Parent := PnlBotRight;
  TrkSize.SetBounds(32, 8, 180, 32);
  BtnShowProps := Toggle(PnlBotRight, 'info', 'Properties of the selection', 228, 2);
  BtnShowProps.OnClick := @ShowPanelClick;
  BtnShowTags := Toggle(PnlBotRight, 'tag', 'Tags of the selection (Ctrl+T)', 274, 2);
  BtnShowTags.OnClick := @ShowPanelClick;
  BtnShowProps.Top := 8;
  BtnShowTags.Top := 8;

  Tray := TPzTray.Create(Self);
  Tray.Parent := PnlBottom;
  Tray.SetBounds(6, 26, 340, 82);
  Tray.Lib := Lib;
  Tray.OnPick := @TrayPick;

  BtnPin := Toggle(PnlBottom, 'pin',
    'Hold: keep the selected photos in the tray', 352, 0);
  BtnPin.SetBounds(352, 28, 34, 38);
  BtnPin.OnClick := @PinClick;
  BtnClearSel := Toggle(PnlBottom, 'clearsel',
    'Clear the tray and the selection', 352, 0);
  BtnClearSel.SetBounds(352, 70, 34, 38);
  BtnClearSel.OnClick := @ClearSelClick;

  X := 398;
  BtnTStar := TB('Star', 'star', 'Star or unstar the photos in the tray (Ctrl+8)',
    84, @TStarClick);
  BtnTRotL := TB('', 'rotleft', 'Rotate counter-clockwise (Ctrl+[)', 36, @TRotLClick);
  BtnTRotR := TB('', 'rotright', 'Rotate clockwise (Ctrl+])', 36, @TRotRClick);
  BtnTTag := TB('Tag', 'tag', 'Add a tag to the photos in the tray (Ctrl+T)',
    80, @TTagClick);
  BtnTExport := TB('Export…', 'export', 'Save edited copies of the photos in the tray',
    104, @ExportClick);

  { the edit view gets its own properties toggle }
  BtnEditInfo := Toggle(PnlEditTop, 'info', 'Properties', 0, 3);
  BtnEditInfo.SetBounds(472, 4, 38, 32);
  BtnEditInfo.OnClick := @ShowPanelClick;
  BtnEditTags := Toggle(PnlEditTop, 'tag', 'Tags (Ctrl+T)', 0, 3);
  BtnEditTags.SetBounds(514, 4, 38, 32);
  BtnEditTags.OnClick := @ShowPanelClick;
  LblName.Left := 562;
end;

procedure TMainForm.BuildRightPanel;
var
  L: TLabel;
  P, Q, R: TPanel;
  k: Integer;
begin
  PnlRight := TPanel.Create(Self);
  PnlRight.Parent := PnlLibrary;
  PnlRight.Align := alRight;
  PnlRight.Width := 300;
  PnlRight.BevelOuter := bvNone;
  PnlRight.Visible := False;
  PnlRight.ShowHint := True;

  RightPages := TPageControl.Create(Self);
  RightPages.Parent := PnlRight;
  RightPages.Align := alClient;
  RightPages.Images := TabIcons;
  RightPages.TabStop := False;

  TabProps := RightPages.AddTabSheet;
  TabProps.Caption := 'Properties';
  TabProps.ImageIndex := PzAddToImageList(TabIcons, 'info');
  LstProps := TListBox.Create(Self);
  LstProps.Parent := TabProps;
  LstProps.Align := alClient;
  LstProps.Style := lbOwnerDrawFixed;
  LstProps.ItemHeight := 38;
  LstProps.Color := TColor($2A2A2A);
  LstProps.OnDrawItem := @PropsDrawItem;
  LstProps.TabStop := False;

  TabTags := RightPages.AddTabSheet;
  TabTags.Caption := 'Tags';
  TabTags.ImageIndex := PzAddToImageList(TabIcons, 'tag');
  { as in Picasa: type a tag and press +, the tags of the photo below,
    Quick Tags at the bottom }
  P := TPanel.Create(Self);
  P.Parent := TabTags;
  P.Align := alTop;
  P.Height := 88;
  P.BevelOuter := bvNone;
  P.ParentColor := True;
  L := TLabel.Create(Self);
  L.Parent := P;
  L.SetBounds(8, 8, 270, 18);
  L.Caption := 'Type in a tag to add:';
  { the edit and its + share a row; aligned, so the + stays at the right edge }
  R := TPanel.Create(Self);
  R.Parent := P;
  R.SetBounds(0, 26, 300, 32);
  R.Align := alTop;
  R.BorderSpacing.Top := 26;
  R.BevelOuter := bvNone;
  R.ParentColor := True;
  BtnAddTag := AddButton(R, '', 0, 0, 34, @AddTagClick, 'plus');
  BtnAddTag.Align := alRight;
  BtnAddTag.BorderSpacing.Right := 8;
  EdTag := TEdit.Create(Self);
  EdTag.Parent := R;
  EdTag.Align := alClient;
  EdTag.BorderSpacing.Left := 8;
  EdTag.BorderSpacing.Right := 4;
  EdTag.TextHint := 'tag1, tag2…';
  EdTag.OnKeyPress := @EdTagKeyPress;
  BtnAddTag.Hint := 'Add the tag to the photos in the tray (Enter)';
  LblTagsIn := TLabel.Create(Self);
  LblTagsIn.Parent := P;
  LblTagsIn.SetBounds(8, 66, 276, 18);
  LblTagsIn.Align := alBottom;
  LblTagsIn.BorderSpacing.Left := 8;
  LblTagsIn.BorderSpacing.Bottom := 4;
  LblTagsIn.Caption := 'Tags in the selection:';

  Q := TPanel.Create(Self);
  Q.Parent := TabTags;
  Q.Align := alBottom;
  Q.Height := 36 + 5 * 32;
  Q.BevelOuter := bvNone;
  Q.ParentColor := True;
  L := TLabel.Create(Self);
  L.Parent := Q;
  L.SetBounds(8, 10, 200, 18);
  L.Caption := 'Quick Tags:';
  R := TPanel.Create(Self);
  R.Parent := Q;
  R.Align := alTop;
  R.Height := 32;
  R.BevelOuter := bvNone;
  R.ParentColor := True;
  L.Parent := R;
  L.Align := alClient;
  L.Layout := tlCenter;
  L.BorderSpacing.Left := 8;
  BtnQuickCfg := TSpeedButton.Create(Self);
  BtnQuickCfg.Parent := R;
  BtnQuickCfg.Width := 32;
  BtnQuickCfg.Align := alRight;
  BtnQuickCfg.BorderSpacing.Right := 8;
  BtnQuickCfg.Flat := True;
  BtnQuickCfg.Hint := 'Configure the Quick Tags';
  BtnQuickCfg.ShowHint := True;
  PzSetGlyph(BtnQuickCfg, 'gear');
  BtnQuickCfg.OnClick := @QuickCfgClick;
  for k := 0 to 9 do
  begin
    QuickBtns[k] := TSpeedButton.Create(Self);
    QuickBtns[k].Parent := Q;
    QuickBtns[k].SetBounds(8 + (k mod 2) * 140, 36 + (k div 2) * 32, 136, 28);
    QuickBtns[k].Tag := k;
    QuickBtns[k].ShowHint := True;
    QuickBtns[k].OnClick := @QuickTagClick;
  end;

  P := TPanel.Create(Self);
  P.Parent := TabTags;
  P.Align := alBottom;
  P.Height := 36;
  P.BevelOuter := bvNone;
  P.ParentColor := True;
  BtnRemoveTag := AddButton(P, 'Remove', 8, 4, 110, @RemoveTagClick, 'cancel');
  BtnRemoveTag.Hint := 'Remove the chosen tag from the photos in the tray (Delete)';

  LstTags := TListBox.Create(Self);
  LstTags.Parent := TabTags;
  LstTags.Align := alClient;
  LstTags.BorderSpacing.Left := 8;
  LstTags.BorderSpacing.Right := 8;
  LstTags.OnKeyDown := @LstTagsKeyDown;

  FQuickTags.StrictDelimiter := True;
  FQuickTags.Delimiter := ';';
  FQuickTags.DelimitedText := Settings.ReadString('tags', 'quick', '');
  while FQuickTags.Count < 10 do
    FQuickTags.Add('');
  RefreshQuickTags;
  RightPages.OnChange := @RightPagesChange;
end;

{ the tray holds the pinned photos and the selection; in the editor it is
  the photo being edited }
procedure TMainForm.TrayPhotos(L: TList);
var
  i: Integer;
  Sel: TList;
begin
  L.Clear;
  if FEditMode then
  begin
    { the editor's tray: the held photos and the one being edited }
    for i := 0 to Held.Count - 1 do
      L.Add(Held[i]);
    if (Cur <> nil) and not Cur.Held then
      L.Add(Cur);
    Exit;
  end;
  for i := 0 to Held.Count - 1 do
    L.Add(Held[i]);
  Sel := TList.Create;
  try
    Grid.SelectionList(Sel);
    for i := 0 to Sel.Count - 1 do
      if not TPzPhoto(Sel[i]).Held then
        L.Add(Sel[i]);
  finally
    Sel.Free;
  end;
end;

{ a photo's place among the photos the library shows in its folder }
function TMainForm.ShownPos(P: TPzPhoto): Integer;
var
  i: Integer;
begin
  Result := 1;
  for i := 0 to P.Index - 1 do
    if Grid.IsShown(P.Folder.Photo(i)) then
      Inc(Result);
end;

procedure TMainForm.SelectionChanged;
var
  L: TList;
  i: Integer;
  Bytes: Int64;
  T0, T1: Int64;
  P: TPzPhoto;
  Dates: string;
begin
  L := TList.Create;
  try
    TrayPhotos(L);
    Tray.SetPhotos(L);
    Bytes := 0;
    T0 := High(Int64);
    T1 := 0;
    for i := 0 to L.Count - 1 do
    begin
      P := TPzPhoto(L[i]);
      Inc(Bytes, P.Size);
      if P.Taken > 0 then
      begin
        T0 := Min(T0, P.Taken);
        T1 := Max(T1, P.Taken);
      end;
      if PnlRight.Visible and (i < 400) then
        Lib.RequestProbe(P); // EXIF for the properties list, in the background
    end;
    Dates := '';
    if T1 > 0 then
    begin
      Dates := FormatDateTime('mmm d, yyyy', UnixToDateTimeSafe(T0));
      if FormatDateTime('yyyymmdd', UnixToDateTimeSafe(T0)) <>
        FormatDateTime('yyyymmdd', UnixToDateTimeSafe(T1)) then
        Dates := Dates + ' – ' + FormatDateTime('mmm d, yyyy', UnixToDateTimeSafe(T1));
    end;
    if FEditMode and (Cur <> nil) then
      { Picasa's line in the edit view: where, when, how big, which of how many }
      LblSummary.Caption := Format(
        '%s  >  %s     %s     %d x %d pixels     %.1f MB     (%d of %d)%s',
        [Cur.Folder.Name, Cur.Name, FormatTaken(Cur.Taken), Cur.W,
        Cur.H, Cur.Size / 1048576, ShownPos(Cur),
        Max(Cur.Folder.ShownCount, ShownPos(Cur)),
        IfThen(Held.Count > 0, Format('     %d held', [Held.Count]), '')])
    else if L.Count = 0 then
      LblSummary.Caption :=
        'No selection — click, Ctrl+click or Shift+click photos; Hold keeps them here'
    else
      LblSummary.Caption := Format('%d picture%s     %s     %.1f MB on disk%s',
        [L.Count, IfThen(L.Count = 1, '', 's'), Dates, Bytes / 1048576,
        IfThen(Held.Count > 0, Format('     (%d held)', [Held.Count]), '')]);
  finally
    L.Free;
  end;
  if PnlRight.Visible then
  begin
    UpdateProps;
    UpdateTags;
  end;
  UpdateStatus;
end;

procedure TMainForm.QueueProps;
begin
  if FPropsQueued then
    Exit;
  FPropsQueued := True;
  Application.QueueAsyncCall(@DoQueuedProps, 0);
end;

procedure TMainForm.DoQueuedProps(Data: PtrInt);
begin
  FPropsQueued := False;
  UpdateProps;
end;

function FmtExposure(e: Single): string;
begin
  if e <= 0 then
    Result := ''
  else if e < 0.5 then
    Result := Format('1/%d s', [Round(1 / e)])
  else
    Result := FormatFloat('0.#', e) + ' s';
end;

procedure TMainForm.UpdateProps;
var
  L: TList;
  N, Pending, i, j, NTop: Integer;
  P: TPzPhoto;
  Bytes: Int64;
  Vals: TStringList;
  Chain: TPzChain;
  E: string;

  { the most common value and, for several photos, how many share it }
  procedure Field(const AName: string);
  var
    k, best: Integer;
    V: string;
  begin
    best := -1;
    for k := 0 to Vals.Count - 1 do
      if (Vals[k] <> '') and ((best < 0) or (PtrInt(Vals.Objects[k]) >
        PtrInt(Vals.Objects[best]))) then
        best := k;
    if best >= 0 then
    begin
      V := Vals[best];
      if N > 1 then
        V := V + Format('   (%d)', [PtrInt(Vals.Objects[best])]);
      LstProps.Items.Add(AName + #9 + V);
    end;
    Vals.Clear;
  end;

  { one date, or the earliest and latest of several }
  procedure DateRange(const AName: string; AFile: Boolean);
  var
    k, cnt: Integer;
    T, A, B: Int64;
  begin
    A := High(Int64);
    B := 0;
    cnt := 0;
    for k := 0 to NTop - 1 do
    begin
      if AFile then
        T := TPzPhoto(L[k]).MTime
      else
        T := TPzPhoto(L[k]).Taken;
      if T <= 0 then
        Continue;
      Inc(cnt);
      A := Min(A, T);
      B := Max(B, T);
    end;
    if cnt = 0 then
      Exit;
    if A = B then
      LstProps.Items.Add(AName + #9 + FormatTaken(A))
    else
      LstProps.Items.Add(AName + #9 + FormatDateTime('yyyy-mm-dd hh:nn',
        UnixToDateTimeSafe(A)) + ' – ' + FormatDateTime('yyyy-mm-dd hh:nn',
        UnixToDateTimeSafe(B)));
  end;

  procedure Add(const V: string);
  var
    k: Integer;
  begin
    if V = '' then
      Exit;
    k := Vals.IndexOf(V);
    if k < 0 then
      Vals.AddObject(V, TObject(PtrInt(1)))
    else
      Vals.Objects[k] := TObject(PtrInt(Vals.Objects[k]) + 1);
  end;

begin
  if not PnlRight.Visible then
    Exit;
  L := TList.Create;
  Vals := TStringList.Create;
  Vals.CaseSensitive := True;
  LstProps.Items.BeginUpdate;
  try
    LstProps.Items.Clear;
    TrayPhotos(L);
    N := L.Count;
    if N = 0 then
    begin
      LstProps.Items.Add('Properties' + #9 + 'nothing selected');
      Exit;
    end;
    NTop := Min(N, 2000);
    Pending := 0;
    Bytes := 0;
    for i := 0 to N - 1 do
      Inc(Bytes, TPzPhoto(L[i]).Size);
    if N > 1 then
      LstProps.Items.Add('Selection' + #9 + Format('%d photos, %.1f MB',
        [N, Bytes / 1048576]))
    else
    begin
      P := TPzPhoto(L[0]);
      LstProps.Items.Add('File name' + #9 + P.Name);
      LstProps.Items.Add('File size' + #9 + Format('%.1f MB  (%d bytes)',
        [P.Size / 1048576, P.Size]));
    end;
    for i := 0 to NTop - 1 do
    begin
      P := TPzPhoto(L[i]);
      P.Folder.EnsureIni;
      if P.MetaState <> 2 then
        Inc(Pending);
    end;
    for i := 0 to NTop - 1 do Add(TPzPhoto(L[i]).Folder.Path);
    Field('Location');
    for i := 0 to NTop - 1 do
    begin
      P := TPzPhoto(L[i]);
      E := UpperCase(Copy(ExtractFileExt(P.Name), 2, 10));
      if P.IsRaw then
        E := E + ' (camera raw)';
      Add(E);
    end;
    Field('Format');
    for i := 0 to NTop - 1 do
      with TPzPhoto(L[i]) do
        if W > 0 then
          Add(Format('%d x %d pixels  (%.1f MP)', [W, H, W * H / 1e6]));
    Field('Dimensions');
    for i := 0 to NTop - 1 do
      with TPzPhoto(L[i]) do
        if MetaState = 2 then Add(Make)
        else
          Add('');
    Field('Camera make');
    for i := 0 to NTop - 1 do
      with TPzPhoto(L[i]) do
        if MetaState = 2 then Add(Model)
        else
          Add(Camera);
    Field('Camera model');
    for i := 0 to NTop - 1 do Add(TPzPhoto(L[i]).Lens);
    Field('Lens');
    DateRange('Camera date', False);
    DateRange('File date (UTC)', True);
    for i := 0 to NTop - 1 do
      with TPzPhoto(L[i]) do
        if Focal > 0 then Add(FormatFloat('0.#', Focal) + ' mm');
    Field('Focal length');
    for i := 0 to NTop - 1 do Add(FmtExposure(TPzPhoto(L[i]).Exposure));
    Field('Exposure time');
    for i := 0 to NTop - 1 do
      with TPzPhoto(L[i]) do
        if FNumber > 0 then Add('f/' + FormatFloat('0.0', FNumber));
    Field('F number');
    for i := 0 to NTop - 1 do
      with TPzPhoto(L[i]) do
        if ISO > 0 then Add(FormatFloat('0', ISO));
    Field('ISO');
    for i := 0 to NTop - 1 do Add(TPzPhoto(L[i]).Caption);
    Field('Caption');
    for i := 0 to NTop - 1 do
      Add(StringReplace(TPzPhoto(L[i]).Keywords, ',', ', ', [rfReplaceAll]));
    Field('Tags');
    for i := 0 to NTop - 1 do Add(IfThen(TPzPhoto(L[i]).Star, 'Yes', 'No'));
    Field('Starred');
    for i := 0 to NTop - 1 do
    begin
      Chain := ParseChain(TPzPhoto(L[i]).Filters);
      E := '';
      for j := 0 to High(Chain) do
        E := E + IfThen(E = '', '', ', ') + Chain[j].Name;
      Add(IfThen(E = '', 'none', E));
    end;
    Field('Edits (filters)');
    for i := 0 to NTop - 1 do
      with TPzPhoto(L[i]) do
        Add(IfThen(Rotate = 0, 'none', IntToStr(Rotate * 90) + '° clockwise'));
    Field('Rotation');
    if Pending > 0 then
      LstProps.Items.Add('EXIF' + #9 + Format('reading %d of %d photos…',
        [Pending, NTop]));
  finally
    LstProps.Items.EndUpdate;
    Vals.Free;
    L.Free;
  end;
end;

procedure TMainForm.PropsDrawItem(Control: TWinControl; Index: Integer;
  ARect: TRect; State: TOwnerDrawState);
var
  C: TCanvas;
  S, AName, AVal: string;
  k: Integer;
begin
  C := LstProps.Canvas;
  S := LstProps.Items[Index];
  k := Pos(#9, S);
  AName := Copy(S, 1, k - 1);
  AVal := Copy(S, k + 1, MaxInt);
  C.Brush.Color := TColor($2A2A2A);
  C.FillRect(ARect);
  C.Pen.Color := TColor($3A3A3A);
  C.Line(ARect.Left + 6, ARect.Bottom - 1, ARect.Right - 6, ARect.Bottom - 1);
  C.Brush.Style := bsClear;
  C.Font.Height := -11;
  C.Font.Style := [fsBold];
  C.Font.Color := TColor($9A9A9A);
  C.TextOut(ARect.Left + 8, ARect.Top + 3, AName);
  C.Font.Style := [];
  C.Font.Height := -13;
  C.Font.Color := TColor($E6E6E6);
  C.TextRect(Rect(ARect.Left + 14, ARect.Top + 18, ARect.Right - 4, ARect.Bottom - 2),
    ARect.Left + 14, ARect.Top + 18, AVal);
  C.Brush.Style := bsSolid;
end;

procedure TMainForm.UpdateTags;
var
  L: TList;
  i, k, j: Integer;
  T: TStringList;
begin
  if not PnlRight.Visible then
    Exit;
  L := TList.Create;
  FTagNames.Clear;
  FTagNames.CaseSensitive := False;
  try
    TrayPhotos(L);
    for i := 0 to L.Count - 1 do
    begin
      TPzPhoto(L[i]).Folder.EnsureIni;
      T := SplitTags(TPzPhoto(L[i]).Keywords);
      try
        for k := 0 to T.Count - 1 do
        begin
          j := FTagNames.IndexOf(T[k]);
          if j < 0 then
            FTagNames.AddObject(T[k], TObject(PtrInt(1)))
          else
            FTagNames.Objects[j] := TObject(PtrInt(FTagNames.Objects[j]) + 1);
        end;
      finally
        T.Free;
      end;
    end;
    LstTags.Items.BeginUpdate;
    LstTags.Items.Clear;
    for i := 0 to FTagNames.Count - 1 do
      LstTags.Items.Add(Format('%s     (%d of %d)',
        [FTagNames[i], PtrInt(FTagNames.Objects[i]), L.Count]));
    LstTags.Items.EndUpdate;
    BtnAddTag.Enabled := L.Count > 0;
    BtnRemoveTag.Enabled := (L.Count > 0) and (FTagNames.Count > 0);
    if L.Count = 0 then
      LblTagsIn.Caption := 'No photo selected'
    else if L.Count = 1 then
      LblTagsIn.Caption := 'Tags in ' + TPzPhoto(L[0]).Name + ':'
    else
      LblTagsIn.Caption := Format('Tags in %d photos:', [L.Count]);
    RefreshQuickTags;
  finally
    L.Free;
  end;
end;

procedure TMainForm.ApplyTag(const ATag: string; AAdd: Boolean);
var
  L: TList;
  i, k: Integer;
  T: TStringList;
  P: TPzPhoto;
  Chg: Boolean;
begin
  L := TList.Create;
  try
    TrayPhotos(L);
    for i := 0 to L.Count - 1 do
    begin
      P := TPzPhoto(L[i]);
      P.Folder.EnsureIni;
      T := SplitTags(P.Keywords);
      T.CaseSensitive := False;
      try
        k := T.IndexOf(ATag);
        Chg := False;
        if AAdd and (k < 0) then
        begin
          T.Add(ATag);
          Chg := True;
        end
        else if not AAdd and (k >= 0) then
        begin
          T.Delete(k);
          Chg := True;
        end;
        if Chg then
        begin
          P.Keywords := JoinTags(T);
          EditsChanged(P);
        end;
      finally
        T.Free;
      end;
    end;
  finally
    L.Free;
  end;
  UpdateTags;
  UpdateProps;
end;

procedure TMainForm.AddTagClick(Sender: TObject);
var
  T: TStringList;
  i: Integer;
begin
  T := SplitTags(EdTag.Text);
  try
    for i := 0 to T.Count - 1 do
      ApplyTag(T[i], True);
  finally
    T.Free;
  end;
  EdTag.Clear;
end;

procedure TMainForm.RemoveTagClick(Sender: TObject);
begin
  if (LstTags.ItemIndex >= 0) and (LstTags.ItemIndex < FTagNames.Count) then
    ApplyTag(FTagNames[LstTags.ItemIndex], False);
end;

procedure TMainForm.EdTagKeyPress(Sender: TObject; var Key: Char);
begin
  if Key = #13 then
  begin
    AddTagClick(nil);
    Key := #0;
  end;
end;

procedure TMainForm.PinClick(Sender: TObject);
var
  L: TList;
  i: Integer;
begin
  L := TList.Create;
  try
    if FEditMode then
    begin
      if Cur <> nil then
        L.Add(Cur);
    end
    else
      Grid.SelectionList(L);
    for i := 0 to L.Count - 1 do
      if not TPzPhoto(L[i]).Held then
      begin
        TPzPhoto(L[i]).Held := True;
        Held.Add(L[i]);
      end;
  finally
    L.Free;
  end;
  SelectionChanged;
end;

procedure TMainForm.ClearSelClick(Sender: TObject);
var
  i: Integer;
begin
  for i := 0 to Held.Count - 1 do
    TPzPhoto(Held[i]).Held := False;
  Held.Clear;
  Grid.ClearSelection;
  SelectionChanged;
end;

procedure TMainForm.TStarClick(Sender: TObject);
var
  L: TList;
begin
  L := TList.Create;
  try
    TrayPhotos(L);
    StarList(L);
  finally
    L.Free;
  end;
end;

procedure TMainForm.TRotLClick(Sender: TObject);
var
  L: TList;
begin
  L := TList.Create;
  try
    TrayPhotos(L);
    RotateList(L, -1);
  finally
    L.Free;
  end;
end;

procedure TMainForm.TRotRClick(Sender: TObject);
var
  L: TList;
begin
  L := TList.Create;
  try
    TrayPhotos(L);
    RotateList(L, 1);
  finally
    L.Free;
  end;
end;

procedure TMainForm.TTagClick(Sender: TObject);
begin
  PnlRight.Visible := True;
  RightPages.ActivePage := TabTags;
  SyncPanelButtons;
  SelectionChanged;
  EdTag.SetFocus;
end;

procedure TMainForm.ShowPanelClick(Sender: TObject);
var
  B: TSpeedButton;
begin
  B := TSpeedButton(Sender);
  PnlRight.Visible := B.Down;
  if (B = BtnShowTags) or (B = BtnEditTags) then
    RightPages.ActivePage := TabTags
  else
    RightPages.ActivePage := TabProps;
  SyncPanelButtons;
  if PnlRight.Visible then
    SelectionChanged;
end;

{ the four toggles (library bar and editor top bar) show one state }
procedure TMainForm.SyncPanelButtons;
var
  V, T: Boolean;
begin
  V := PnlRight.Visible;
  T := RightPages.ActivePage = TabTags;
  BtnShowProps.Down := V and not T;
  BtnEditInfo.Down := V and not T;
  BtnShowTags.Down := V and T;
  BtnEditTags.Down := V and T;
end;

procedure TMainForm.RightPagesChange(Sender: TObject);
begin
  SyncPanelButtons;
end;

procedure TMainForm.TrayPick(Sender: TObject; P: TPzPhoto);
begin
  if FEditMode then
  begin
    ShowPhoto(P);
    Exit;
  end;
  if Grid.IsShown(P) and (P.Folder <> nil) and P.Folder.Visible then
    Grid.EnsureVisible(P);
end;

{ ---------------- Picasa's edit-view tiles, caption, histogram, quick tags ---------------- }

function TMainForm.AddTile(AParent: TWinControl; const ACaption, AIcon, AHint: string;
  X, Y: Integer; H: TNotifyEvent): TSpeedButton;
var
  Bmp: TBitmap;
begin
  Result := TSpeedButton.Create(Self);
  Result.Parent := AParent;
  Result.SetBounds(X, Y, 80, 72);
  Result.Caption := ACaption;
  Result.Layout := blGlyphTop;
  Result.Spacing := 4;
  Result.Flat := True;
  Result.Font.Height := -11;
  Result.Font.Color := clPzHeader;
  Result.Hint := AHint;
  Result.ShowHint := True;
  Result.OnClick := H;
  Bmp := PzIconBitmap(AIcon, 2 * PzIconSize - 8);
  if Bmp <> nil then
    try
      Result.Glyph.Assign(Bmp);
    finally
      Bmp.Free;
    end;
end;

procedure TMainForm.StraightenClick(Sender: TObject);
begin
  { the slider and a levelling grid only while straightening }
  if BtnStraighten.Down then
    PnlStraighten.Top := 157; // right under the tiles, above Fill Light
  PnlStraighten.Visible := BtnStraighten.Down;
  Viewer.ShowGrid := BtnStraighten.Down;
  if BtnStraighten.Down and (Viewer.Mode = vmCrop) then
    CropCancelClick(nil);
end;

procedure TMainForm.SaveCaption;
begin
  if (Cur = nil) or (EdCaption.Text = Cur.Caption) then
    Exit;
  Cur.Folder.EnsureIni;
  Cur.Caption := EdCaption.Text;
  EditsChanged(Cur);
end;

procedure TMainForm.CaptionKeyPress(Sender: TObject; var Key: Char);
begin
  if Key = #13 then
  begin
    SaveCaption;
    Viewer.SetFocus;
    Key := #0;
  end
  else if Key = #27 then
  begin
    if Cur <> nil then
      EdCaption.Text := Cur.Caption;
    Viewer.SetFocus;
    Key := #0;
  end;
end;

procedure TMainForm.CaptionExit(Sender: TObject);
begin
  SaveCaption;
end;

procedure TMainForm.UpdateHistInfo;
var
  S: string;
begin
  Hist.Lines.Clear;
  if Cur = nil then
  begin
    Hist.Invalidate;
    Exit;
  end;
  if Cur.MetaState = 2 then
  begin
    Hist.Lines.Add(Trim(Cur.Make + '  ' + Cur.Model));
    S := FmtExposure(Cur.Exposure);
    if Cur.FNumber > 0 then
      S := S + '   f/' + FormatFloat('0.0', Cur.FNumber);
    if Cur.ISO > 0 then
      S := S + '   ISO ' + FormatFloat('0', Cur.ISO);
    Hist.Lines.Add(Trim(S));
    if Cur.Focal > 0 then
      Hist.Lines.Add('Focal length: ' + FormatFloat('0.#', Cur.Focal) + ' mm');
    if Cur.Lens <> '' then
      Hist.Lines.Add(Cur.Lens);
  end
  else
    Hist.Lines.Add(Cur.Camera);
  Hist.Lines.Add(Format('%d x %d pixels   %.1f MB', [Cur.W, Cur.H, Cur.Size / 1048576]));
  Hist.Invalidate;
end;

procedure TMainForm.RefreshQuickTags;
var
  k, i, n: Integer;
  L: TList;
  T: TStringList;
  All: Boolean;
begin
  L := TList.Create;
  try
    TrayPhotos(L);
    for k := 0 to 9 do
    begin
      if FQuickTags[k] = '' then
      begin
        QuickBtns[k].Caption := '?';
        QuickBtns[k].Hint := 'Click to choose a tag for this button';
        QuickBtns[k].Font.Style := [];
        Continue;
      end;
      QuickBtns[k].Caption := FQuickTags[k];
      { bold when every photo in the tray already has it }
      All := L.Count > 0;
      n := 0;
      for i := 0 to L.Count - 1 do
      begin
        T := SplitTags(TPzPhoto(L[i]).Keywords);
        T.CaseSensitive := False;
        if T.IndexOf(FQuickTags[k]) >= 0 then
          Inc(n)
        else
          All := False;
        T.Free;
      end;
      if All then
        QuickBtns[k].Font.Style := [fsBold]
      else
        QuickBtns[k].Font.Style := [];
      QuickBtns[k].Hint := Format(
        'Toggle "%s" on the photos in the tray (%d of %d have it)',
        [FQuickTags[k], n, L.Count]);
    end;
  finally
    L.Free;
  end;
end;

procedure TMainForm.SaveQuickTags;
begin
  FQuickTags.StrictDelimiter := True;
  FQuickTags.Delimiter := ';';
  Settings.WriteString('tags', 'quick', FQuickTags.DelimitedText);
end;

procedure TMainForm.QuickTagClick(Sender: TObject);
var
  k, i: Integer;
  S: string;
  L: TList;
  T: TStringList;
  All: Boolean;
begin
  k := TSpeedButton(Sender).Tag;
  if FQuickTags[k] = '' then
  begin
    S := '';
    if InputQuery('Quick Tag', 'Tag for this button:', S) and (Trim(S) <> '') then
    begin
      FQuickTags[k] := StringReplace(Trim(S), ',', ' ', [rfReplaceAll]);
      SaveQuickTags;
      RefreshQuickTags;
    end;
    Exit;
  end;
  { like Picasa: add the tag, or take it off when every photo has it }
  L := TList.Create;
  try
    TrayPhotos(L);
    All := L.Count > 0;
    for i := 0 to L.Count - 1 do
    begin
      TPzPhoto(L[i]).Folder.EnsureIni;
      T := SplitTags(TPzPhoto(L[i]).Keywords);
      T.CaseSensitive := False;
      All := All and (T.IndexOf(FQuickTags[k]) >= 0);
      T.Free;
    end;
    if L.Count > 0 then
      ApplyTag(FQuickTags[k], not All);
  finally
    L.Free;
  end;
end;

procedure TMainForm.QuickCfgClick(Sender: TObject);
var
  F: TForm;
  M: TMemo;
  B1, B2: TButton;
  L: TLabel;
  i: Integer;
begin
  F := TForm.CreateNew(nil);
  try
    F.Caption := 'Configure Quick Tags';
    F.Width := 320;
    F.Height := 340;
    F.Position := poOwnerFormCenter;
    L := TLabel.Create(F);
    L.Parent := F;
    L.SetBounds(10, 8, 300, 18);
    L.Caption := 'One tag per line, up to ten:';
    M := TMemo.Create(F);
    M.Parent := F;
    M.SetBounds(10, 30, 300, 250);
    for i := 0 to 9 do
      M.Lines.Add(FQuickTags[i]);
    B1 := TButton.Create(F);
    B1.Parent := F;
    B1.SetBounds(130, 292, 84, 30);
    B1.Caption := 'OK';
    B1.ModalResult := mrOk;
    B1.Default := True;
    B2 := TButton.Create(F);
    B2.Parent := F;
    B2.SetBounds(222, 292, 84, 30);
    B2.Caption := 'Cancel';
    B2.ModalResult := mrCancel;
    B2.Cancel := True;
    if F.ShowModal = mrOk then
    begin
      for i := 0 to 9 do
        if i < M.Lines.Count then
          FQuickTags[i] := StringReplace(Trim(M.Lines[i]), ',', ' ', [rfReplaceAll])
        else
          FQuickTags[i] := '';
      SaveQuickTags;
      RefreshQuickTags;
    end;
  finally
    F.Free;
  end;
end;

procedure TMainForm.LstTagsKeyDown(Sender: TObject; var Key: Word; Shift: TShiftState);
begin
  if Key = VK_DELETE then
  begin
    RemoveTagClick(nil);
    Key := 0;
  end;
end;

{ ---------------- 1:1 view: hand cursors, double-click, click, wheel ---------------- }

const
  crPzHand = 21;
  crPzGrab = 22;

procedure TMainForm.MakeCursors;

  function Make(const AIcon: string; ID: TCursor): Boolean;
  var
    Bmp: TBitmap;
    CI: TCursorImage;
  begin
    Result := False;
    Bmp := PzIconBitmap(AIcon, 32);
    if Bmp = nil then
      Exit;
    CI := TCursorImage.Create;
    try
      CI.Assign(Bmp);
      CI.HotSpot := Point(Bmp.Width div 2, Bmp.Height div 2);
      Screen.Cursors[ID] := CI.ReleaseHandle;
      Result := True;
    except
      Result := False;
    end;
    CI.Free;
    Bmp.Free;
  end;

begin
  if Make('hand', crPzHand) then
    Viewer.HandCursor := crPzHand
  else
    Viewer.HandCursor := crHandPoint;
  if Make('grab', crPzGrab) then
    Viewer.GrabCursor := crPzGrab
  else
    Viewer.GrabCursor := crSizeAll;
end;

procedure TMainForm.ViewerZoomAt(Sender: TObject; NX, NY: Double);
begin
  if (Cur = nil) or Viewer.Zoom100 then
    Exit;
  Viewer.SetZoomCenter(NX, NY);
  ZoomClick(Viewer);
end;

procedure TMainForm.ViewerUnzoom(Sender: TObject);
begin
  if Viewer.Zoom100 then
    ZoomClick(Viewer);
end;

procedure TMainForm.ViewerWheel(Sender: TObject; Delta: Integer);
begin
  if Viewer.Mode = vmNormal then
    Navigate(Delta);
end;

{ ---------------- context menus: photos, the photo view, albums ---------------- }

function TMainForm.AddMI(AMenu: TPopupMenu; const ACaption, AIcon, AKeys: string;
  H: TNotifyEvent): TMenuItem;
var
  Bmp: TBitmap;
begin
  Result := TMenuItem.Create(AMenu);
  if ACaption = '-' then
  begin
    Result.Caption := '-';
    AMenu.Items.Add(Result);
    Exit;
  end;
  Result.Caption := ACaption;
  Result.OnClick := H;
  if AKeys <> '' then
    Result.ShortCut := TextToShortCut(AKeys); // shown only: the menus are not attached
  if AIcon <> '' then
  begin
    Bmp := PzIconBitmap(AIcon, 16);
    if Bmp <> nil then
      try
        Result.Bitmap.Assign(Bmp);
      finally
        Bmp.Free;
      end;
  end;
  AMenu.Items.Add(Result);
end;

procedure TMainForm.BuildMenus;
begin
  { a photo in the library grid }
  PmPhoto := TPopupMenu.Create(Self);
  MiOpen := AddMI(PmPhoto, 'Open in Editor', 'zoom100', 'Enter', @MOpenClick);
  AddMI(PmPhoto, 'Open with Default Application', '', '', @MDefaultAppClick);
  AddMI(PmPhoto, '-', '', '', nil);
  AddMI(PmPhoto, 'Star / Unstar', 'star', 'Ctrl+8', @MStarClick);
  AddMI(PmPhoto, 'Rotate Clockwise', 'rotright', 'Ctrl+]', @MRotRClick);
  AddMI(PmPhoto, 'Rotate Counter-clockwise', 'rotleft', 'Ctrl+[', @MRotLClick);
  AddMI(PmPhoto, 'Add Tag…', 'tag', 'Ctrl+T', @TTagClick);
  AddMI(PmPhoto, 'Hold in Tray', 'pin', '', @PinClick);
  MiHidePhoto := AddMI(PmPhoto, 'Hide', 'hide', '', @MHideClick);
  AddMI(PmPhoto, '-', '', '', nil);
  AddMI(PmPhoto, 'Copy Edits', '', '', @MCopyEditsClick);
  MiPastePhoto := AddMI(PmPhoto, 'Paste Edits', '', '', @MPasteEditsClick);
  AddMI(PmPhoto, 'Undo All Edits', 'undoall', '', @MUndoAllClick);
  AddMI(PmPhoto, '-', '', '', nil);
  AddMI(PmPhoto, 'Export…', 'export', '', @MExportClick);
  AddMI(PmPhoto, 'Copy File Path', '', '', @MCopyPathClick);
  AddMI(PmPhoto, 'Show in File Manager', 'folder', '', @MShowFileClick);
  AddMI(PmPhoto, 'Delete from Disk…', 'trash', 'Del', @MDeleteClick);
  AddMI(PmPhoto, '-', '', '', nil);
  AddMI(PmPhoto, 'Select All in Folder', 'library', 'Ctrl+A', @MSelectAllClick);
  AddMI(PmPhoto, 'Properties', 'info', '', @MPropsClick);

  { the photo view }
  PmView := TPopupMenu.Create(Self);
  AddMI(PmView, 'Back to Library', 'library', 'Esc', @BackClick);
  MiZoom := AddMI(PmView, 'Actual Pixels (1:1)', 'zoom100', '1', @MZoomClick);
  AddMI(PmView, '-', '', '', nil);
  AddMI(PmView, 'Star / Unstar', 'star', 'Ctrl+8', @MStarClick);
  AddMI(PmView, 'Rotate Clockwise', 'rotright', 'Ctrl+]', @MRotRClick);
  AddMI(PmView, 'Rotate Counter-clockwise', 'rotleft', 'Ctrl+[', @MRotLClick);
  AddMI(PmView, 'Add Tag…', 'tag', 'Ctrl+T', @TTagClick);
  AddMI(PmView, 'Hold in Tray', 'pin', '', @PinClick);
  MiHideView := AddMI(PmView, 'Hide', 'hide', '', @MHideClick);
  AddMI(PmView, '-', '', '', nil);
  AddMI(PmView, 'Copy Edits', '', '', @MCopyEditsClick);
  MiPasteView := AddMI(PmView, 'Paste Edits', '', '', @MPasteEditsClick);
  AddMI(PmView, 'Undo All Edits', 'undoall', '', @MUndoAllClick);
  AddMI(PmView, '-', '', '', nil);
  AddMI(PmView, 'Export…', 'export', '', @MExportClick);
  AddMI(PmView, 'Open with Default Application', '', '', @MDefaultAppClick);
  AddMI(PmView, 'Show in File Manager', 'folder', '', @MShowFileClick);
  AddMI(PmView, 'Copy File Path', '', '', @MCopyPathClick);
  AddMI(PmView, 'Delete from Disk…', 'trash', 'Del', @MDeleteClick);
  AddMI(PmView, '-', '', '', nil);
  AddMI(PmView, 'Properties', 'info', '', @MPropsClick);

  { an album: in the folder list or a folder header in the grid }
  PmFolder := TPopupMenu.Create(Self);
  MiFSelect := AddMI(PmFolder, 'Select All Photos', 'library', '', @MFSelectClick);
  MiFHold := AddMI(PmFolder, 'Hold All in Tray', 'pin', '', @MFHoldClick);
  MiFExport := AddMI(PmFolder, 'Export Album…', 'export', '', @MFExportClick);
  AddMI(PmFolder, '-', '', '', nil);
  MiFDesc := AddMI(PmFolder, 'Edit Description…', 'tag', '', @MFDescClick);
  MiFShow := AddMI(PmFolder, 'Show in File Manager', 'folder', '', @MFShowClick);
  MiFCopy := AddMI(PmFolder, 'Copy Folder Path', '', '', @MFCopyClick);
  MiFRescan := AddMI(PmFolder, 'Rescan Folder', 'search', '', @MFRescanClick);
  AddMI(PmFolder, '-', '', '', nil);
  AddMI(PmFolder, 'Expand All Years', 'calendar', '', @MFExpandClick);
  AddMI(PmFolder, 'Collapse All Years', 'calendar', '', @MFCollapseClick);
end;

{ what a photo menu acts on: the selection, or the photo being edited }
procedure TMainForm.TargetPhotos(L: TList);
begin
  L.Clear;
  if FEditMode then
  begin
    if Cur <> nil then
      L.Add(Cur);
  end
  else
    Grid.SelectionList(L);
end;

procedure TMainForm.StarList(L: TList);
var
  i: Integer;
  All: Boolean;
begin
  All := L.Count > 0;
  for i := 0 to L.Count - 1 do
  begin
    TPzPhoto(L[i]).Folder.EnsureIni;
    All := All and TPzPhoto(L[i]).Star;
  end;
  { like Picasa: star them all, or unstar if every one is starred }
  for i := 0 to L.Count - 1 do
    if TPzPhoto(L[i]).Star = All then
      ToggleStar(TPzPhoto(L[i]));
  Tray.Invalidate;
  if PnlRight.Visible then
    UpdateProps;
end;

procedure TMainForm.RotateList(L: TList; Delta: Integer);
var
  i: Integer;
begin
  for i := 0 to L.Count - 1 do
    RotatePhoto(TPzPhoto(L[i]), Delta);
  if PnlRight.Visible then
    UpdateProps;
end;

procedure TMainForm.GridContextPopup(Sender: TObject; MousePos: TPoint;
  var Handled: Boolean);
var
  P: TPzPhoto;
begin
  Handled := True;
  P := Grid.HitTest(MousePos.X, MousePos.Y);
  if P <> nil then
  begin
    if not P.Selected then
      Grid.Select(P); // right-click on another photo selects it, as in Picasa
    MiPastePhoto.Enabled := FEditsClip <> '';
    SetHideCaption(MiHidePhoto);
    PmPhoto.PopUp;
    Exit;
  end;
  FMenuFolder := Grid.HitFolder(MousePos.X, MousePos.Y);
  if FMenuFolder <> nil then
    PopupFolderMenu;
end;

procedure TMainForm.ViewerContextPopup(Sender: TObject; MousePos: TPoint;
  var Handled: Boolean);
begin
  Handled := True;
  if Cur = nil then
    Exit;
  if Viewer.Zoom100 then
    MiZoom.Caption := 'Fit to Window'
  else
    MiZoom.Caption := 'Actual Pixels (1:1)';
  MiPasteView.Enabled := FEditsClip <> '';
  SetHideCaption(MiHideView);
  PmView.PopUp;
end;

procedure TMainForm.TreeContextPopup(Sender: TObject; MousePos: TPoint;
  var Handled: Boolean);
var
  N: TTreeNode;
begin
  Handled := True;
  N := Tree.GetNodeAt(MousePos.X, MousePos.Y);
  if N <> nil then
    FMenuFolder := TPzFolder(N.Data)
  else
    FMenuFolder := nil;
  PopupFolderMenu;
end;

procedure TMainForm.PopupFolderMenu;
var
  Ok: Boolean;
begin
  { a year or empty space: only the expand/collapse items apply }
  Ok := FMenuFolder <> nil;
  MiFSelect.Enabled := Ok;
  MiFHold.Enabled := Ok;
  MiFExport.Enabled := Ok;
  MiFDesc.Enabled := Ok;
  MiFShow.Enabled := Ok;
  MiFCopy.Enabled := Ok;
  MiFRescan.Enabled := Ok;
  PmFolder.PopUp;
end;

procedure TMainForm.MOpenClick(Sender: TObject);
begin
  if Grid.Selected <> nil then
    GridOpen(Grid, Grid.Selected);
end;

procedure TMainForm.MDefaultAppClick(Sender: TObject);
var
  L: TList;
  i: Integer;
begin
  L := TList.Create;
  try
    TargetPhotos(L);
    for i := 0 to Min(L.Count, 10) - 1 do // a handful, not a thousand windows
      OpenDocument(TPzPhoto(L[i]).Path);
  finally
    L.Free;
  end;
end;

function AllHidden(L: TList): Boolean;
var
  i: Integer;
begin
  Result := L.Count > 0;
  for i := 0 to L.Count - 1 do
  begin
    TPzPhoto(L[i]).Folder.EnsureIni;
    Result := Result and TPzPhoto(L[i]).Hidden;
  end;
end;

procedure TMainForm.SetHideCaption(Mi: TMenuItem);
var
  L: TList;
begin
  L := TList.Create;
  try
    TargetPhotos(L);
    if AllHidden(L) then
      Mi.Caption := 'Unhide'
    else
      Mi.Caption := 'Hide';
  finally
    L.Free;
  end;
end;

{ like Picasa's Hide/Unhide: hidden=yes in .picasa.ini; hidden photos leave
  the library unless 'Hidden' is down }
procedure TMainForm.MHideClick(Sender: TObject);
var
  L: TList;
  i: Integer;
  ToHide: Boolean;
  N: TPzPhoto;
begin
  L := TList.Create;
  try
    TargetPhotos(L);
    if L.Count = 0 then
      Exit;
    ToHide := not AllHidden(L);
    { the editor moves on when its photo disappears from the library }
    N := nil;
    if FEditMode and ToHide and not Grid.ShowHidden then
    begin
      N := Grid.NextPhoto(Cur, 1);
      if N = nil then
        N := Grid.NextPhoto(Cur, -1);
    end;
    for i := 0 to L.Count - 1 do
    begin
      Lib.SetHidden(TPzPhoto(L[i]), ToHide);
      EditsChanged(TPzPhoto(L[i]));
      if ToHide and not Grid.ShowHidden then
        Grid.Forget(TPzPhoto(L[i]));
    end;
    Grid.Relayout;
    Strip.Invalidate;
    Tray.Invalidate;
    if N <> nil then
      ShowPhoto(N)
    else
      SelectionChanged;
  finally
    L.Free;
  end;
end;

procedure TMainForm.MDeleteClick(Sender: TObject);
var
  L: TList;
begin
  L := TList.Create;
  try
    TargetPhotos(L);
    DeletePhotos(L);
  finally
    L.Free;
  end;
end;

{ Picasa's 'Delete from Disk': the files go to the desktop trash, from where
  they can be restored (their .picasa.ini entries are kept for that) }
procedure TMainForm.DeletePhotos(L: TList);
var
  i, k: Integer;
  P, N: TPzPhoto;
  Msg, Err, FirstErr: string;
  Gone, Failed: TList;
begin
  if L.Count = 0 then
    Exit;
  if PzIniReadOnly then
  begin
    MessageDlg('Delete from Disk', 'Pizzicato is running read-only (--readonly); ' +
      'nothing is deleted.', mtInformation, [mbOK], 0);
    Exit;
  end;
  if L.Count = 1 then
    Msg := Format('Move "%s" to the trash?', [TPzPhoto(L[0]).Name])
  else
    Msg := Format('Move these %d photos to the trash?', [L.Count]);
  if MessageDlg('Delete from Disk', Msg + LineEnding + LineEnding +
    'The files are removed from their folders; they can be restored ' +
    'from the trash.', mtWarning, [mbYes, mbCancel], 0) <> mrYes then
    Exit;
  { where to go afterwards: the next photo that survives }
  if FEditMode then
    N := Cur
  else
    N := Grid.Selected;
  if (N <> nil) and (L.IndexOf(N) < 0) then
    N := nil;
  if N <> nil then
  begin
    P := N;
    repeat
      N := Grid.NextPhoto(N, 1);
    until (N = nil) or (L.IndexOf(N) < 0);
    if N = nil then
    begin
      N := P;
      repeat
        N := Grid.NextPhoto(N, -1);
      until (N = nil) or (L.IndexOf(N) < 0);
    end;
  end;
  Gone := TList.Create;
  Failed := TList.Create;
  try
    FirstErr := '';
    Screen.Cursor := crHourGlass;
    try
      for i := 0 to L.Count - 1 do
      begin
        P := TPzPhoto(L[i]);
        if PzTrashFile(P.Path, Err) then
          Gone.Add(P)
        else
        begin
          Failed.Add(P);
          if FirstErr = '' then
            FirstErr := Err;
        end;
      end;
    finally
      Screen.Cursor := crDefault;
    end;
    if (Failed.Count > 0) and (MessageDlg('Delete from Disk',
      Format('%d of %d files could not be moved to the trash:',
      [Failed.Count, L.Count]) + LineEnding + FirstErr + LineEnding +
      LineEnding + 'Delete them permanently? This cannot be undone.',
      mtError, [mbYes, mbNo], 0, mbNo) = mrYes) then
      for i := 0 to Failed.Count - 1 do
        if DeleteFile(TPzPhoto(Failed[i]).Path) then
          Gone.Add(Failed[i]);
    for i := 0 to Gone.Count - 1 do
    begin
      P := TPzPhoto(Gone[i]);
      if P.Held then
      begin
        P.Held := False;
        Held.Remove(P);
      end;
      for k := Cache.Count - 1 downto 0 do
        if TViewEntry(Cache[k]).Photo = P then
        begin
          TViewEntry(Cache[k]).Free;
          Cache.Delete(k);
        end;
      Grid.Forget(P);
      Lib.RemovePhoto(P);
    end;
    if Gone.Count = 0 then
      Exit;
    FTreeDirty := True;
    Grid.Relayout;
    Strip.Invalidate;
    if FEditMode and (Gone.IndexOf(Cur) >= 0) then
    begin
      if N <> nil then
        ShowPhoto(N)
      else
      begin
        Cur := nil;
        SetEditMode(False);
      end;
    end
    else if not FEditMode and (N <> nil) then
      Grid.Select(N);
    SelectionChanged;
    UpdateStatus;
  finally
    Gone.Free;
    Failed.Free;
  end;
end;

procedure TMainForm.MStarClick(Sender: TObject);
var
  L: TList;
begin
  L := TList.Create;
  try
    TargetPhotos(L);
    StarList(L);
  finally
    L.Free;
  end;
end;

procedure TMainForm.MRotRClick(Sender: TObject);
var
  L: TList;
begin
  L := TList.Create;
  try
    TargetPhotos(L);
    RotateList(L, 1);
  finally
    L.Free;
  end;
end;

procedure TMainForm.MRotLClick(Sender: TObject);
var
  L: TList;
begin
  L := TList.Create;
  try
    TargetPhotos(L);
    RotateList(L, -1);
  finally
    L.Free;
  end;
end;

procedure TMainForm.MCopyEditsClick(Sender: TObject);
var
  L: TList;
begin
  L := TList.Create;
  try
    TargetPhotos(L);
    if L.Count = 0 then
      Exit;
    TPzPhoto(L[0]).Folder.EnsureIni;
    FEditsClip := TPzPhoto(L[0]).Filters;
    if FEditsClip = '' then
      Status.SimpleText := 'This photo has no edits to copy'
    else
      Status.SimpleText := 'Edits copied: ' + FEditsClip;
  finally
    L.Free;
  end;
end;

procedure TMainForm.MPasteEditsClick(Sender: TObject);
var
  L: TList;
  i: Integer;
  P: TPzPhoto;
begin
  if FEditsClip = '' then
    Exit;
  L := TList.Create;
  try
    TargetPhotos(L);
    for i := 0 to L.Count - 1 do
    begin
      P := TPzPhoto(L[i]);
      P.Folder.EnsureIni;
      { Picasa's "paste all effects": the copied chain replaces the photo's;
        the old one goes on the redo stack so it can be brought back }
      if P.Filters <> '' then
        P.Redo := P.Filters + P.Redo;
      P.Filters := FEditsClip;
      EditsChanged(P);
    end;
  finally
    L.Free;
  end;
  if FEditMode then
    LoadSlidersFromChain;
end;

procedure TMainForm.MUndoAllClick(Sender: TObject);
var
  L: TList;
  i: Integer;
  P: TPzPhoto;
begin
  L := TList.Create;
  try
    TargetPhotos(L);
    for i := 0 to L.Count - 1 do
    begin
      P := TPzPhoto(L[i]);
      P.Folder.EnsureIni;
      if P.Filters = '' then
        Continue;
      P.Redo := P.Filters + P.Redo;
      P.Filters := '';
      EditsChanged(P);
    end;
  finally
    L.Free;
  end;
  if FEditMode then
    LoadSlidersFromChain;
end;

procedure TMainForm.MExportClick(Sender: TObject);
var
  L: TList;
  Dir: string;
begin
  L := TList.Create;
  try
    TargetPhotos(L);
    if (L.Count > 0) and SelectDirectory('Export to folder',
      GetEnvironmentVariable('HOME'), Dir) then
      ExportPhotos(L, Dir);
  finally
    L.Free;
  end;
end;

procedure TMainForm.MCopyPathClick(Sender: TObject);
var
  L: TList;
  i: Integer;
  S: string;
begin
  L := TList.Create;
  try
    TargetPhotos(L);
    S := '';
    for i := 0 to L.Count - 1 do
      S := S + IfThen(S = '', '', LineEnding) + TPzPhoto(L[i]).Path;
    if S <> '' then
      Clipboard.AsText := S;
  finally
    L.Free;
  end;
end;

procedure TMainForm.MShowFileClick(Sender: TObject);
var
  L: TList;
begin
  L := TList.Create;
  try
    TargetPhotos(L);
    if L.Count > 0 then
      OpenDocument(TPzPhoto(L[0]).Folder.Path);
  finally
    L.Free;
  end;
end;

procedure TMainForm.MSelectAllClick(Sender: TObject);
begin
  if Grid.Selected <> nil then
    Grid.SelectAllInFolder(Grid.Selected.Folder);
end;

procedure TMainForm.MPropsClick(Sender: TObject);
begin
  PnlRight.Visible := True;
  RightPages.ActivePage := TabProps;
  SyncPanelButtons;
  SelectionChanged;
end;

procedure TMainForm.MZoomClick(Sender: TObject);
begin
  ZoomClick(nil);
end;

procedure TMainForm.MFSelectClick(Sender: TObject);
begin
  if FMenuFolder = nil then
    Exit;
  if FEditMode then
    SetEditMode(False);
  FMenuFolder.EnsureIni;
  if FMenuFolder.Count > 0 then
  begin
    Grid.Select(FMenuFolder.Photo(0));
    Grid.SelectAllInFolder(FMenuFolder);
    Grid.ScrollToFolder(FMenuFolder);
  end;
end;

procedure TMainForm.MFHoldClick(Sender: TObject);
var
  k: Integer;
  P: TPzPhoto;
begin
  if FMenuFolder = nil then
    Exit;
  for k := 0 to FMenuFolder.Count - 1 do
  begin
    P := FMenuFolder.Photo(k);
    if Grid.IsShown(P) and not P.Held then
    begin
      P.Held := True;
      Held.Add(P);
    end;
  end;
  SelectionChanged;
end;

procedure TMainForm.MFExportClick(Sender: TObject);
var
  L: TList;
  k: Integer;
  Dir: string;
begin
  if FMenuFolder = nil then
    Exit;
  if not SelectDirectory('Export album "' + FMenuFolder.Name +
    '" to folder', GetEnvironmentVariable('HOME'), Dir) then
    Exit;
  L := TList.Create;
  try
    for k := 0 to FMenuFolder.Count - 1 do
      if Grid.IsShown(FMenuFolder.Photo(k)) then
        L.Add(FMenuFolder.Photo(k));
    if L.Count > 0 then
      ExportPhotos(L, Dir);
  finally
    L.Free;
  end;
end;

procedure TMainForm.MFDescClick(Sender: TObject);
var
  S: string;
begin
  if FMenuFolder = nil then
    Exit;
  FMenuFolder.EnsureIni;
  S := FMenuFolder.Description;
  if not InputQuery('Album description', 'Description of "' +
    FMenuFolder.Name + '":', S) then
    Exit;
  FMenuFolder.SetDescription(Trim(S));
  if FDirtyFolders.IndexOf(FMenuFolder) < 0 then
    FDirtyFolders.Add(FMenuFolder);
  TmrIni.Enabled := False;
  TmrIni.Enabled := True;
  Grid.Invalidate;
end;

procedure TMainForm.MFShowClick(Sender: TObject);
begin
  if FMenuFolder <> nil then
    OpenDocument(FMenuFolder.Path);
end;

procedure TMainForm.MFCopyClick(Sender: TObject);
begin
  if FMenuFolder <> nil then
    Clipboard.AsText := FMenuFolder.Path;
end;

procedure TMainForm.MFRescanClick(Sender: TObject);
begin
  if FMenuFolder = nil then
    Exit;
  { forget the folder's time stamp so the scanner reads it again }
  FMenuFolder.DirMTime := 0;
  Lib.StartScan;
  Status.SimpleText := 'Rescanning ' + FMenuFolder.Path + ' …';
end;

procedure TMainForm.MFExpandClick(Sender: TObject);
begin
  Tree.FullExpand;
end;

procedure TMainForm.MFCollapseClick(Sender: TObject);
begin
  Tree.FullCollapse;
end;

{$I pzbench.inc}


end.
