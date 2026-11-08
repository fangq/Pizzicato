{ Pizzicato main window: library mode (folder tree + continuous grid) and
  edit mode (Picasa-style Basic Fixes / Tuning / Effects panel, viewer,
  filmstrip). Also hosts the --bench driver. }
unit mainform;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Forms, Controls, Graphics, StdCtrls, ExtCtrls, ComCtrls, Dialogs,
  LCLType, LCLIntf, IniFiles, Math, StrUtils, Menus, DateUtils,
  Buttons, ImgList,
  pzcorebind, pzini, pzrender, pzlibrary, pzviews, pzicons;

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
    BtnAdd: TBitBtn;
    EdSearch: TEdit;
    ChkStar: TSpeedButton;   // 'starred only' toggle
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
    procedure BuildBottomBar;
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
  Held := TList.Create;
  FTagNames := TStringList.Create;
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
  FEffNames.Free;
  Held.Free;
  FTagNames.Free;
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
  ChkRawPreview := TCheckBox.Create(Self);
  ChkRawPreview.Parent := PnlTop;
  ChkRawPreview.SetBounds(506, 10, 200, 22);
  ChkRawPreview.Caption := 'RAW: use camera preview';
  ChkRawPreview.Font.Color := clPzHeader;
  ChkRawPreview.Checked := Settings.ReadBool('view', 'rawpreview', True);
  ChkRawPreview.OnChange := @RawModeChange;
  ImgSize := AddIcon(PnlTop, 'thumbsize', 716, 10);
  ImgSize.Hint := 'Thumbnail size';
  ImgSize.ShowHint := True;
  L := nil;
  TrkSize := TTrackBar.Create(Self);
  TrkSize.Parent := PnlTop;
  TrkSize.SetBounds(740, 4, 180, 32);
  TrkSize.Min := 64;
  TrkSize.Max := 320;
  TrkSize.Frequency := 32;
  TrkSize.Position := Settings.ReadInteger('view', 'thumbsize', 160);
  TrkSize.OnChange := @SizeChange;
  TrkSize.TabStop := False;
  LblStatus := TLabel.Create(Self);
  LblStatus.Parent := PnlTop;
  LblStatus.SetBounds(936, 12, 500, 20);
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

  BtnUndo := AddButton(PnlTools, 'Undo', 6, 4, 80, @UndoClick, 'undo');
  BtnUndo.Hint := 'Undo the last edit (Ctrl+Z)';
  BtnRedo := AddButton(PnlTools, 'Redo', 90, 4, 80, @RedoClick, 'redo');
  BtnRedo.Hint := 'Redo (Ctrl+Y)';
  BtnUndoAll := AddButton(PnlTools, 'All', 174, 4, 82, @UndoAllClick, 'undoall');
  BtnUndoAll.Hint := 'Undo all edits of this photo';
  PnlEdit.ShowHint := True;
  TabIcons := TImageList.Create(Self);
  TabIcons.Width := PzIconSize;
  TabIcons.Height := PzIconSize;

  Pages := TPageControl.Create(Self);
  Pages.Parent := PnlTools;
  Pages.SetBounds(0, 38, 262, 560);
  Pages.Anchors := [akLeft, akTop, akRight, akBottom];
  Pages.TabStop := False;
  Pages.Images := TabIcons;

  { Basic fixes }
  TS := Pages.AddTabSheet;
  TS.Caption := 'Basic';
  TabIcon('tab_basic');
  BtnCrop := AddButton(TS, 'Crop', 8, 8, 112, @CropClick, 'crop');
  CmbAspect := TComboBox.Create(Self);
  CmbAspect.Parent := TS;
  CmbAspect.SetBounds(128, 8, 116, 28);
  CmbAspect.Style := csDropDownList;
  CmbAspect.Items.CommaText := 'Free,"4:3","3:2","16:9","1:1","5:4","3:4","2:3"';
  CmbAspect.ItemIndex := 0;
  CmbAspect.OnChange := @AspectChange;
  CmbAspect.TabStop := False;
  BtnCropApply := AddButton(TS, 'Apply', 8, 40, 112, @CropApplyClick, 'apply');
  BtnCropApply.Hint := 'Apply the crop (Enter)';
  BtnCropCancel := AddButton(TS, 'Cancel', 128, 40, 116, @CropCancelClick, 'cancel');
  BtnCropApply.Enabled := False;
  BtnCropCancel.Enabled := False;
  Eff('I''m Feeling Lucky', 'enhance', 'Automatic contrast and colour in one click',
    8, 78, 236);
  Eff('Auto Contrast', 'autolight', 'Stretch the brightness range', 8, 110, 236);
  Eff('Auto Color', 'autocolor', 'Remove a colour cast', 8, 142, 236);
  Y := 182;
  AddSlider(TS, 'Straighten', -100, 100, skTilt, Y);
  AddSlider(TS, 'Fill Light', 0, 100, skFill, Y);

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
  Eff('Black && White', 'bw', 'Convert to black and white', 8, 8, 116);
  Eff('Sepia', 'sepia', 'Old-photo brown tone', 128, 8, 116);
  Eff('Warmify', 'warm', 'Warmer colours', 8, 40, 116);
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
    jkProbe:
      if PnlRight.Visible then
        QueueProps;
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
  { the properties/tags panel follows into the editor }
  if AOn then
    PnlRight.Parent := PnlEdit
  else
    PnlRight.Parent := PnlLibrary;
  BtnEditInfo.Down := PnlRight.Visible;
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
  if P.Star then BtnStar.Caption := 'Starred'
  else
    BtnStar.Caption := 'Star';
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
  if PnlRight.Visible then
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
  AppendFilter(FEffNames[TControl(Sender).Tag], []);
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
  if not PnlRight.Visible then
    Settings.WriteInteger('view', 'rightpanel', 0)
  else if RightPages.ActivePage = TabTags then
    Settings.WriteInteger('view', 'rightpanel', 2)
  else
    Settings.WriteInteger('view', 'rightpanel', 1);
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
  PnlBottom.Parent := PnlLibrary;
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
  LblName.Left := 520;
end;

procedure TMainForm.BuildRightPanel;
var
  L: TLabel;
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
  L := TLabel.Create(Self);
  L.Parent := TabTags;
  L.SetBounds(8, 8, 270, 18);
  L.Caption := 'Add tags to the photos in the tray:';
  EdTag := TEdit.Create(Self);
  EdTag.Parent := TabTags;
  EdTag.SetBounds(8, 30, 190, 28);
  EdTag.TextHint := 'tag1, tag2…';
  EdTag.OnKeyPress := @EdTagKeyPress;
  BtnAddTag := AddButton(TabTags, 'Add', 204, 30, 80, @AddTagClick, 'tag');
  L := TLabel.Create(Self);
  L.Parent := TabTags;
  L.SetBounds(8, 68, 270, 18);
  L.Caption := 'Tags in the tray (photos that have it):';
  LstTags := TListBox.Create(Self);
  LstTags.Parent := TabTags;
  LstTags.SetBounds(8, 90, 276, 300);
  LstTags.Anchors := [akLeft, akTop, akRight, akBottom];
  BtnRemoveTag := AddButton(TabTags, 'Remove tag', 8, 398, 140,
    @RemoveTagClick, 'cancel');
  BtnRemoveTag.Anchors := [akLeft, akBottom];
  BtnRemoveTag.Hint := 'Remove the chosen tag from every photo in the tray';
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
    if Cur <> nil then
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
    if not FEditMode then
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
    if L.Count = 0 then
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
  i: Integer;
  All: Boolean;
begin
  L := TList.Create;
  try
    TrayPhotos(L);
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
  finally
    L.Free;
  end;
  Tray.Invalidate;
  if PnlRight.Visible then
    UpdateProps;
end;

procedure TMainForm.TRotLClick(Sender: TObject);
var
  L: TList;
  i: Integer;
begin
  L := TList.Create;
  try
    TrayPhotos(L);
    for i := 0 to L.Count - 1 do
      RotatePhoto(TPzPhoto(L[i]), -1);
  finally
    L.Free;
  end;
  if PnlRight.Visible then
    UpdateProps;
end;

procedure TMainForm.TRotRClick(Sender: TObject);
var
  L: TList;
  i: Integer;
begin
  L := TList.Create;
  try
    TrayPhotos(L);
    for i := 0 to L.Count - 1 do
      RotatePhoto(TPzPhoto(L[i]), 1);
  finally
    L.Free;
  end;
  if PnlRight.Visible then
    UpdateProps;
end;

procedure TMainForm.TTagClick(Sender: TObject);
begin
  PnlRight.Visible := True;
  RightPages.ActivePage := TabTags;
  BtnShowTags.Down := True;
  BtnEditInfo.Down := True;
  SelectionChanged;
  EdTag.SetFocus;
end;

procedure TMainForm.ShowPanelClick(Sender: TObject);
var
  B: TSpeedButton;
begin
  B := TSpeedButton(Sender);
  PnlRight.Visible := B.Down;
  if B = BtnEditInfo then
  begin
    BtnShowProps.Down := B.Down;
    if not B.Down then
      BtnShowTags.Down := False;
  end
  else
    BtnEditInfo.Down := B.Down;
  if B = BtnShowTags then
    RightPages.ActivePage := TabTags
  else
    RightPages.ActivePage := TabProps;
  if PnlRight.Visible then
    SelectionChanged;
end;

procedure TMainForm.TrayPick(Sender: TObject; P: TPzPhoto);
begin
  if Grid.IsShown(P) and (P.Folder <> nil) and P.Folder.Visible then
    Grid.EnsureVisible(P);
end;

{$I pzbench.inc}

end.
