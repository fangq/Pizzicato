{ Custom-drawn controls: the continuous library grid (Picasa style, all
  folders in one scroll with folder headers), the image viewer and the
  filmstrip. }
unit pzviews;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Controls, Graphics, StdCtrls, ExtCtrls, Forms, LCLType, LCLIntf,
  GraphType, IntfGraphics, pzcorebind, pzlibrary;

const
  clPzBack = TColor($262626);
  clPzHeader = TColor($D8D8D8);
  clPzSub = TColor($8C8C8C);
  clPzSel = TColor($E0A040);  // BGR: a warm blue-ish highlight
  clPzCell = TColor($333333);
  HEADER_H = 40;
  CELL_PAD = 10;
  MAX_BITMAPS = 2500;

type
  TPzPhotoEvent = procedure(Sender: TObject; P: TPzPhoto) of object;
  TPzSelMode = (smReplace, smToggle, smRange);

  { TPzGrid }

  TPzGrid = class(TCustomControl)
  private
    FLib: TPzLibrary;
    FScroll: TScrollBar;
    FThumbSize: Integer;
    FScrollY: Integer;
    FTotalH: Integer;
    FCols: Integer;
    FCell: Integer;
    FShown: TList;        // folders currently laid out
    FSelected: TPzPhoto;  // focus
    FAnchor: TPzPhoto;    // start of a shift-click range
    FSel: TList;          // the selection, in click order
    FFolderIcon: TBitmap;
    FStarOnly: Boolean;
    FFilter: string;
    FOnOpen: TPzPhotoEvent;
    FOnSelect: TPzPhotoEvent;
    FOnTopFolder: TNotifyEvent;
    FLruClock: Int64;
    FBitmapCount: Integer;
    FLastTop: TPzFolder;
    procedure ScrollChange(Sender: TObject);
    procedure SetThumbSize(AValue: Integer);
    procedure SetStarOnly(AValue: Boolean);
    procedure SetFilter(const AValue: string);
    function CellRect(F: TPzFolder; i: Integer): TRect;
    function PhotoVisible(P: TPzPhoto): Boolean;
    procedure EvictBitmaps;
  protected
    procedure Paint; override;
    procedure Resize; override;
    procedure MouseDown(Button: TMouseButton; Shift: TShiftState;
      X, Y: Integer); override;
    procedure DblClick; override;
    function DoMouseWheel(Shift: TShiftState; WheelDelta: Integer;
      MousePos: TPoint): Boolean; override;
    procedure KeyDown(var Key: Word; Shift: TShiftState); override;
  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;
    procedure Relayout;
    procedure SetScrollY(Y: Integer);
    function HitTest(X, Y: Integer): TPzPhoto;
    procedure ScrollToFolder(F: TPzFolder);
    procedure EnsureVisible(P: TPzPhoto);
    procedure Select(P: TPzPhoto; Mode: TPzSelMode = smReplace);
    procedure ClearSelection;
    procedure SelectAllInFolder(F: TPzFolder);
    function OrderKey(P: TPzPhoto): Int64;
    procedure SetFolderIcon(B: TBitmap);
    procedure ThumbArrived(P: TPzPhoto; Bmp: TBitmap);
    function TopFolder: TPzFolder;
    function IsShown(P: TPzPhoto): Boolean;
    procedure SelectionList(L: TList);
    function NextPhoto(P: TPzPhoto; Delta: Integer): TPzPhoto;
    function VisibleReady(out Total, Ready: Integer): Boolean;
    property ScrollY: Integer read FScrollY;
    property TotalHeight: Integer read FTotalH;
    property Lib: TPzLibrary read FLib write FLib;
    property ThumbSize: Integer read FThumbSize write SetThumbSize;
    property Selected: TPzPhoto read FSelected;
    property StarOnly: Boolean read FStarOnly write SetStarOnly;
    property Filter: string read FFilter write SetFilter;
    property OnOpen: TPzPhotoEvent read FOnOpen write FOnOpen;
    property OnSelect: TPzPhotoEvent read FOnSelect write FOnSelect;
    property OnTopFolder: TNotifyEvent read FOnTopFolder write FOnTopFolder;
    property Shown: TList read FShown;
  end;

  TPzViewMode = (vmNormal, vmCrop, vmPick);
  TPzPickEvent = procedure(Sender: TObject; NX, NY: Double) of object;

  { TPzViewer }

  TPzViewer = class(TCustomControl)
  private
    FBmp: TBitmap;        // rendered image (owned)
    FPlaceholder: TBitmap; // not owned
    FZoom100: Boolean;
    FPanX, FPanY: Integer;
    FDragging: Boolean;
    FDragStart: TPoint;
    FPanStart: TPoint;
    FMode: TPzViewMode;
    FCropAspect: Double; // 0 = free
    FCropA, FCropB: TPoint; // in image coords of FBmp
    FHasCrop: Boolean;
    FOnPick: TPzPickEvent;
    FOnNav: TNotifyEvent;
    FInfo: string;
    FShowGrid: Boolean;
    procedure SetShowGrid(AValue: Boolean);
    function ImageRect: TRect;
    function ToImage(X, Y: Integer): TPoint;
  protected
    procedure Paint; override;
    procedure MouseDown(Button: TMouseButton; Shift: TShiftState;
      X, Y: Integer); override;
    procedure MouseMove(Shift: TShiftState; X, Y: Integer); override;
    procedure MouseUp(Button: TMouseButton; Shift: TShiftState; X, Y: Integer); override;
  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;
    procedure SetImage(B: TBitmap);   // takes ownership
    procedure SetPlaceholder(B: TBitmap);
    procedure SetMode(M: TPzViewMode);
    function CropRectNorm(out L, T, R, B: Double): Boolean;
    property Zoom100: Boolean read FZoom100 write FZoom100;
    property ShowGrid: Boolean read FShowGrid write SetShowGrid;
    property Mode: TPzViewMode read FMode;
    property CropAspect: Double read FCropAspect write FCropAspect;
    property OnPick: TPzPickEvent read FOnPick write FOnPick;
    property Info: string read FInfo write FInfo;
    property Bmp: TBitmap read FBmp;
  end;

  { TPzStrip }

  TPzStrip = class(TCustomControl)
  private
    FFolder: TPzFolder;
    FCurrent: TPzPhoto;
    FOffset: Integer;
    FOnPick: TPzPhotoEvent;
    FLib: TPzLibrary;
    FThumbSize: Integer;
    function ItemW: Integer;
  protected
    procedure Paint; override;
    procedure MouseDown(Button: TMouseButton; Shift: TShiftState;
      X, Y: Integer); override;
    function DoMouseWheel(Shift: TShiftState; WheelDelta: Integer;
      MousePos: TPoint): Boolean; override;
  public
    constructor Create(AOwner: TComponent); override;
    procedure SetCurrent(P: TPzPhoto);
    property Lib: TPzLibrary read FLib write FLib;
    property ThumbSize: Integer read FThumbSize write FThumbSize;
    property OnPick: TPzPhotoEvent read FOnPick write FOnPick;
  end;

  { TPzHistogram: Picasa's "Histogram & Camera Information" box }

  TPzHistogram = class(TCustomControl)
  private
    FHist: Tpz_hist;
    FHave: Boolean;
    FLines: TStringList;
  protected
    procedure Paint; override;
  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;
    procedure SetHistogram(const H: Tpz_hist);
    procedure Clear;
    property Lines: TStringList read FLines;
  end;

  { TPzTray: Picasa's photo tray -- the held photos and the selection }

  TPzTray = class(TCustomControl)
  private
    FPhotos: TList;   // not owned
    FOffset: Integer;
    FLib: TPzLibrary;
    FThumbSize: Integer;
    FOnPick: TPzPhotoEvent;
    function ItemW: Integer;
  protected
    procedure Paint; override;
    procedure MouseDown(Button: TMouseButton; Shift: TShiftState;
      X, Y: Integer); override;
    function DoMouseWheel(Shift: TShiftState; WheelDelta: Integer;
      MousePos: TPoint): Boolean; override;
  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;
    procedure SetPhotos(L: TList);
    property Photos: TList read FPhotos;
    property Lib: TPzLibrary read FLib write FLib;
    property ThumbSize: Integer read FThumbSize write FThumbSize;
    property OnPick: TPzPhotoEvent read FOnPick write FOnPick;
  end;

function ImageToBitmap(const Img: Tpz_image): TBitmap;
procedure DrawStar(C: TCanvas; X, Y, R: Integer);

implementation

uses
  Math;

function ImageToBitmap(const Img: Tpz_image): TBitmap;
var
  Raw: TRawImage;
begin
  Result := TBitmap.Create;
  if (Img.px = nil) or (Img.w <= 0) or (Img.h <= 0) then
    Exit;
  Raw.Init;
  Raw.Description.Init_BPP32_B8G8R8_BIO_TTB(Img.w, Img.h);
  Raw.Data := PByte(Img.px);
  Raw.DataSize := PtrUInt(Img.w) * PtrUInt(Img.h) * 4;
  Result.LoadFromRawImage(Raw, False);
end;

procedure DrawStar(C: TCanvas; X, Y, R: Integer);
var
  Pts: array[0..9] of TPoint;
  i: Integer;
  a, rr: Double;
begin
  for i := 0 to 9 do
  begin
    a := -Pi / 2 + i * Pi / 5;
    if Odd(i) then rr := R * 0.45
    else
      rr := R;
    Pts[i] := Point(X + Round(Cos(a) * rr), Y + Round(Sin(a) * rr));
  end;
  C.Pen.Color := TColor($202020);
  C.Brush.Color := TColor($30C8F8);
  C.Polygon(Pts);
end;

{ TPzGrid }

constructor TPzGrid.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  FShown := TList.Create;
  FSel := TList.Create;
  FThumbSize := 160;
  Color := clPzBack;
  TabStop := True;
  DoubleBuffered := True;
  FScroll := TScrollBar.Create(Self);
  FScroll.Kind := sbVertical;
  FScroll.Align := alRight;
  FScroll.Parent := Self;
  FScroll.OnChange := @ScrollChange;
  FScroll.TabStop := False;
end;

destructor TPzGrid.Destroy;
begin
  FShown.Free;
  FSel.Free;
  FFolderIcon.Free;
  inherited Destroy;
end;

procedure TPzGrid.ScrollChange(Sender: TObject);
begin
  if FScroll.Position <> FScrollY then
  begin
    FScrollY := FScroll.Position;
    Invalidate;
  end;
end;

procedure TPzGrid.SetThumbSize(AValue: Integer);
var
  Anchor: TPzPhoto;
  OldTop: TPzFolder;
  Rel: Double;
begin
  if AValue = FThumbSize then
    Exit;
  { keep the folder at the top of the view anchored while resizing }
  OldTop := TopFolder;
  Rel := 0;
  if (OldTop <> nil) and (OldTop.Height > 0) then
    Rel := (FScrollY - OldTop.Top) / OldTop.Height;
  FThumbSize := AValue;
  Relayout;
  if OldTop <> nil then
    SetScrollY(OldTop.Top + Round(Rel * OldTop.Height));
  Anchor := FSelected;
  if Anchor <> nil then
    EnsureVisible(Anchor);
  Invalidate;
end;

procedure TPzGrid.SetStarOnly(AValue: Boolean);
begin
  if FStarOnly = AValue then
    Exit;
  FStarOnly := AValue;
  Relayout;
  SetScrollY(0);
end;

procedure TPzGrid.SetFilter(const AValue: string);
begin
  if FFilter = AValue then
    Exit;
  FFilter := AValue;
  Relayout;
  SetScrollY(0);
end;

function TPzGrid.IsShown(P: TPzPhoto): Boolean;
begin
  Result := (P <> nil) and (not FStarOnly or P.Star) and
    ((FFilter = '') or P.FilterHit or ((P.Folder <> nil) and P.Folder.FilterAll));
end;

procedure TPzGrid.Relayout;
var
  i, k, n, Y, W, Rows: Integer;
  F: TPzFolder;
  Low: string;
begin
  FShown.Clear;
  if FLib = nil then
    Exit;
  FCell := FThumbSize + CELL_PAD;
  W := ClientWidth - FScroll.Width - CELL_PAD;
  FCols := Max(1, W div FCell);
  Y := 0;
  Low := LowerCase(FFilter);
  for i := 0 to FLib.Folders.Count - 1 do
  begin
    F := TPzFolder(FLib.Folders[i]);
    F.Visible := False;
    { like Picasa's search: a matching folder shows all of it, otherwise
      only the photos whose name or tags match }
    F.FilterAll := (Low = '') or (Pos(Low, LowerCase(F.Path)) > 0);
    if not F.FilterAll then
    begin
      F.EnsureIni;
      for k := 0 to F.Count - 1 do
        F.Photo(k).FilterHit :=
          Pos(Low, LowerCase(F.Photo(k).Name + ' ' + F.Photo(k).Keywords +
          ' ' + F.Photo(k).Caption)) > 0;
    end;
    if FStarOnly then
      F.EnsureIni;
    if FStarOnly or not F.FilterAll then
    begin
      n := 0;
      for k := 0 to F.Count - 1 do
        if IsShown(F.Photo(k)) then
          Inc(n);
    end
    else
      n := F.Count;
    if n = 0 then
      Continue;
    F.Visible := True;
    Rows := (n + FCols - 1) div FCols;
    F.Top := Y;
    F.Height := HEADER_H + Rows * FCell + CELL_PAD;
    Inc(Y, F.Height);
    FShown.Add(F);
  end;
  FTotalH := Y;
  FScroll.Max := Max(0, FTotalH);
  FScroll.PageSize := Max(1, ClientHeight);
  FScroll.LargeChange := Max(1, ClientHeight - FCell);
  FScroll.SmallChange := Max(1, FCell div 3);
  if FScrollY > Max(0, FTotalH - ClientHeight) then
    SetScrollY(FTotalH - ClientHeight);
  Invalidate;
end;

procedure TPzGrid.SetScrollY(Y: Integer);
begin
  Y := Max(0, Min(Y, FTotalH - ClientHeight));
  if Y = FScrollY then
    Exit;
  FScrollY := Y;
  FScroll.Position := Y;
  Invalidate;
end;

procedure TPzGrid.Resize;
begin
  inherited Resize;
  Relayout;
end;

{ position of the i-th shown photo of a folder, in content coordinates }
function TPzGrid.CellRect(F: TPzFolder; i: Integer): TRect;
var
  r, c: Integer;
begin
  r := i div FCols;
  c := i mod FCols;
  Result.Left := CELL_PAD + c * FCell;
  Result.Top := F.Top + HEADER_H + r * FCell;
  Result.Right := Result.Left + FThumbSize;
  Result.Bottom := Result.Top + FThumbSize;
end;

function TPzGrid.PhotoVisible(P: TPzPhoto): Boolean;
begin
  Result := IsShown(P) and (P.Folder <> nil) and P.Folder.Visible;
end;

procedure SortInt64(var A: array of Int64; L, R: Integer);
var
  i, j: Integer;
  p, t: Int64;
begin
  while L < R do
  begin
    i := L;
    j := R;
    p := A[(L + R) shr 1];
    repeat
      while A[i] < p do Inc(i);
      while A[j] > p do Dec(j);
      if i <= j then
      begin
        t := A[i];
        A[i] := A[j];
        A[j] := t;
        Inc(i);
        Dec(j);
      end;
    until i > j;
    if j - L < R - i then
    begin
      SortInt64(A, L, j);
      L := i;
    end
    else
    begin
      SortInt64(A, i, R);
      R := j;
    end;
  end;
end;

procedure TPzGrid.EvictBitmaps;
var
  i, k, n: Integer;
  F: TPzFolder;
  P: TPzPhoto;
  Stamps: array of Int64;
  Cut: Int64;
begin
  { drop the least recently drawn bitmaps, down to 80% of the budget }
  SetLength(Stamps, 0);
  n := 0;
  for i := 0 to FLib.Folders.Count - 1 do
  begin
    F := TPzFolder(FLib.Folders[i]);
    for k := 0 to F.Count - 1 do
      if F.Photo(k).Bmp <> nil then
      begin
        if n >= Length(Stamps) then
          SetLength(Stamps, n * 2 + 256);
        Stamps[n] := F.Photo(k).LruStamp;
        Inc(n);
      end;
  end;
  if n <= MAX_BITMAPS then
  begin
    FBitmapCount := n;
    Exit;
  end;
  SetLength(Stamps, n);
  { find cut-off stamp by partial sort }
  SortInt64(Stamps, 0, n - 1);
  Cut := Stamps[n - (MAX_BITMAPS * 8) div 10];
  FBitmapCount := 0;
  for i := 0 to FLib.Folders.Count - 1 do
  begin
    F := TPzFolder(FLib.Folders[i]);
    for k := 0 to F.Count - 1 do
    begin
      P := F.Photo(k);
      if P.Bmp <> nil then
      begin
        if P.LruStamp < Cut then
          FreeAndNil(P.Bmp)
        else
          Inc(FBitmapCount);
      end;
    end;
  end;
end;

procedure TPzGrid.ThumbArrived(P: TPzPhoto; Bmp: TBitmap);
begin
  if P.Bmp = nil then
    Inc(FBitmapCount);
  P.Bmp.Free;
  P.Bmp := Bmp;
  Inc(FLruClock);
  P.LruStamp := FLruClock;
  if FBitmapCount > MAX_BITMAPS + 200 then
    EvictBitmaps;
  { cheap: only repaint when the photo is on screen }
  if Visible and PhotoVisible(P) then
    Invalidate;
end;

procedure TPzGrid.Paint;
var
  C: TCanvas;
  i, k, j, idx, Y0, Y1, Lo, Hi, Mid, FirstRow, LastRow: Integer;
  F: TPzFolder;
  P: TPzPhoto;
  R, D: TRect;
  s: Double;
  Hdr, Sub: string;
  Need: TList;
  Key: string;
  Prefetch: Integer;
begin
  C := Canvas;
  C.Brush.Color := clPzBack;
  C.FillRect(ClientRect);
  if (FLib = nil) or (FShown.Count = 0) then
  begin
    C.Font.Color := clPzSub;
    C.Font.Height := -16;
    C.TextOut(24, 24, 'No photos yet — use "Add Folder" to choose your photo folders.');
    Exit;
  end;
  Inc(FLib.Epoch);
  Need := TList.Create;
  try
    Prefetch := ClientHeight div 2;
    Y0 := FScrollY - Prefetch;
    Y1 := FScrollY + ClientHeight + Prefetch;
    { binary search first visible folder }
    Lo := 0;
    Hi := FShown.Count - 1;
    while Lo < Hi do
    begin
      Mid := (Lo + Hi) div 2;
      F := TPzFolder(FShown[Mid]);
      if F.Top + F.Height <= Y0 then
        Lo := Mid + 1
      else
        Hi := Mid;
    end;
    for i := Lo to FShown.Count - 1 do
    begin
      F := TPzFolder(FShown[i]);
      if F.Top > Y1 then
        Break;
      F.EnsureIni;
      { header }
      if (F.Top + HEADER_H > FScrollY) and (F.Top < FScrollY + ClientHeight) then
      begin
        C.Font.Height := -15;
        C.Font.Style := [fsBold];
        C.Font.Color := clPzHeader;
        Hdr := F.Name;
        C.Brush.Style := bsClear;
        j := CELL_PAD;
        if FFolderIcon <> nil then
        begin
          C.Draw(CELL_PAD, F.Top - FScrollY + (HEADER_H - 4 - FFolderIcon.Height) div
            2, FFolderIcon);
          j := CELL_PAD + FFolderIcon.Width + 8;
        end;
        C.TextOut(j, F.Top - FScrollY + 10, Hdr);
        C.Font.Style := [];
        C.Font.Height := -12;
        C.Font.Color := clPzSub;
        Sub := Format('%d photos   %s', [F.Count, ExtractFileDir(F.Path)]);
        C.TextOut(j + C.TextWidth(Hdr) * 15 div 12 + 24, F.Top -
          FScrollY + 13, Sub);
        C.Pen.Color := TColor($3A3A3A);
        C.Line(CELL_PAD, F.Top - FScrollY + HEADER_H - 4, ClientWidth -
          FScroll.Width - CELL_PAD,
          F.Top - FScrollY + HEADER_H - 4);
        C.Brush.Style := bsSolid;
      end;
      FirstRow := Max(0, (Y0 - F.Top - HEADER_H) div FCell);
      LastRow := (Y1 - F.Top - HEADER_H) div FCell;
      idx := -1;
      for k := 0 to F.Count - 1 do
      begin
        P := F.Photo(k);
        if not IsShown(P) then
          Continue;
        Inc(idx);
        j := idx div FCols;
        if j < FirstRow then
          Continue;
        if j > LastRow then
          Break;
        R := CellRect(F, idx);
        OffsetRect(R, 0, -FScrollY);
        Key := P.EditKey;
        if (P.Bmp = nil) or (P.BmpSize <> FThumbSize) or (P.BmpEdits <> Key) then
        begin
          P.WantEpoch := FLib.Epoch;
          if not P.BmpPending and not P.Failed then
            Need.Add(P);
        end;
        if (R.Bottom < 0) or (R.Top > ClientHeight) then
          Continue;
        if P.Selected then
        begin
          C.Brush.Color := clPzSel;
          C.FillRect(Rect(R.Left - 4, R.Top - 4, R.Right + 4, R.Bottom + 4));
        end;
        if P.Bmp <> nil then
        begin
          Inc(FLruClock);
          P.LruStamp := FLruClock;
          s := Min(FThumbSize / P.Bmp.Width, FThumbSize / P.Bmp.Height);
          if (P.BmpSize = FThumbSize) and (s >= 1) then
            s := 1;
          D.Left := 0;
          D.Right := Round(P.Bmp.Width * s);
          D.Top := 0;
          D.Bottom := Round(P.Bmp.Height * s);
          OffsetRect(D, R.Left + (FThumbSize - D.Right) div 2, R.Top +
            (FThumbSize - D.Bottom) div 2);
          if (D.Right - D.Left = P.Bmp.Width) and (D.Bottom - D.Top = P.Bmp.Height) then
            C.Draw(D.Left, D.Top, P.Bmp)
          else
            C.StretchDraw(D, P.Bmp);
        end
        else
        begin
          C.Brush.Color := clPzCell;
          C.FillRect(Rect(R.Left + FThumbSize div 8, R.Top + FThumbSize div
            4, R.Right - FThumbSize div 8, R.Bottom - FThumbSize div 4));
          if P.Failed then
          begin
            C.Font.Color := clPzSub;
            C.Font.Height := -11;
            C.Brush.Style := bsClear;
            C.TextOut(R.Left + 8, R.Top + FThumbSize div 2 - 6, P.Name);
            C.Brush.Style := bsSolid;
          end;
        end;
        if P.Star then
          DrawStar(C, R.Left + 10, R.Bottom - 10, 7);
        if P.IsRaw and (FThumbSize >= 96) then
        begin
          C.Font.Height := -9;
          C.Font.Style := [fsBold];
          C.Font.Color := TColor($E0E0E0);
          C.Brush.Color := TColor($505050);
          C.TextOut(R.Right - C.TextWidth('RAW') - 6, R.Bottom - 14, 'RAW');
          C.Font.Style := [];
        end;
      end;
    end;
    { request missing thumbnails: farthest first so the LIFO queue serves the
      visible middle of the window first }
    for i := Need.Count - 1 downto 0 do
      FLib.RequestThumb(TPzPhoto(Need[i]), FThumbSize);
  finally
    Need.Free;
  end;
  F := TopFolder;
  if (F <> FLastTop) then
  begin
    FLastTop := F;
    if Assigned(FOnTopFolder) then
      FOnTopFolder(Self);
  end;
end;

function TPzGrid.TopFolder: TPzFolder;
var
  Lo, Hi, Mid: Integer;
  F: TPzFolder;
begin
  Result := nil;
  if FShown.Count = 0 then
    Exit;
  Lo := 0;
  Hi := FShown.Count - 1;
  while Lo < Hi do
  begin
    Mid := (Lo + Hi) div 2;
    F := TPzFolder(FShown[Mid]);
    if F.Top + F.Height <= FScrollY + 1 then
      Lo := Mid + 1
    else
      Hi := Mid;
  end;
  Result := TPzFolder(FShown[Lo]);
end;

function TPzGrid.HitTest(X, Y: Integer): TPzPhoto;
var
  i, k, idx, r, c, cy: Integer;
  F: TPzFolder;
begin
  Result := nil;
  cy := Y + FScrollY;
  for i := 0 to FShown.Count - 1 do
  begin
    F := TPzFolder(FShown[i]);
    if (cy >= F.Top + HEADER_H) and (cy < F.Top + F.Height) then
    begin
      r := (cy - F.Top - HEADER_H) div FCell;
      c := (X - CELL_PAD div 2) div FCell;
      if (c < 0) or (c >= FCols) then
        Exit;
      idx := r * FCols + c;
      for k := 0 to F.Count - 1 do
      begin
        if not IsShown(F.Photo(k)) then
          Continue;
        if idx = 0 then
          Exit(F.Photo(k));
        Dec(idx);
      end;
      Exit;
    end;
  end;
end;

function TPzGrid.OrderKey(P: TPzPhoto): Int64;
begin
  Result := Int64(FShown.IndexOf(P.Folder)) * 10000000 + P.Index;
end;

procedure TPzGrid.ClearSelection;
var
  i: Integer;
begin
  for i := 0 to FSel.Count - 1 do
    TPzPhoto(FSel[i]).Selected := False;
  FSel.Clear;
  Invalidate;
end;

procedure TPzGrid.Select(P: TPzPhoto; Mode: TPzSelMode);
var
  A, B, Q: TPzPhoto;
  guard: Integer;
begin
  if P = nil then
    Exit;
  case Mode of
    smReplace:
    begin
      ClearSelection;
      P.Selected := True;
      FSel.Add(P);
      FAnchor := P;
    end;
    smToggle:
    begin
      P.Selected := not P.Selected;
      if P.Selected then
        FSel.Add(P)
      else
        FSel.Remove(P);
      FAnchor := P;
    end;
    smRange:
    begin
      if (FAnchor = nil) or not IsShown(FAnchor) then
        FAnchor := P;
      ClearSelection;
      A := FAnchor;
      B := P;
      if OrderKey(A) > OrderKey(B) then
      begin
        A := P;
        B := FAnchor;
      end;
      Q := A;
      guard := 0;
      while (Q <> nil) and (guard < 1000000) do
      begin
        Q.Selected := True;
        FSel.Add(Q);
        if Q = B then
          Break;
        Q := NextPhoto(Q, 1);
        Inc(guard);
      end;
    end;
  end;
  FSelected := P;
  Invalidate;
  if Assigned(FOnSelect) then
    FOnSelect(Self, P);
end;

procedure TPzGrid.SelectAllInFolder(F: TPzFolder);
var
  k: Integer;
begin
  if F = nil then
    Exit;
  ClearSelection;
  for k := 0 to F.Count - 1 do
    if IsShown(F.Photo(k)) then
    begin
      F.Photo(k).Selected := True;
      FSel.Add(F.Photo(k));
    end;
  Invalidate;
  if Assigned(FOnSelect) then
    FOnSelect(Self, FSelected);
end;

procedure TPzGrid.SelectionList(L: TList);
var
  i: Integer;
begin
  L.Clear;
  for i := 0 to FSel.Count - 1 do
    L.Add(FSel[i]);
end;

procedure TPzGrid.SetFolderIcon(B: TBitmap);
begin
  FFolderIcon.Free;
  FFolderIcon := B;
end;

procedure TPzGrid.MouseDown(Button: TMouseButton; Shift: TShiftState; X, Y: Integer);
var
  P: TPzPhoto;
begin
  inherited MouseDown(Button, Shift, X, Y);
  SetFocus;
  P := HitTest(X, Y);
  if P = nil then
    Exit;
  if ssShift in Shift then
    Select(P, smRange)
  else if ssCtrl in Shift then
    Select(P, smToggle)
  else if not P.Selected or (Button = mbLeft) then
    Select(P, smReplace);
end;

procedure TPzGrid.DblClick;
begin
  inherited DblClick;
  if (FSelected <> nil) and Assigned(FOnOpen) then
    FOnOpen(Self, FSelected);
end;

function TPzGrid.DoMouseWheel(Shift: TShiftState; WheelDelta: Integer;
  MousePos: TPoint): Boolean;
begin
  if ssCtrl in Shift then
  begin
    if WheelDelta > 0 then
      ThumbSize := Min(320, ThumbSize + 16)
    else
      ThumbSize := Max(64, ThumbSize - 16);
  end
  else
    SetScrollY(FScrollY - WheelDelta * FCell div 120);
  Result := True;
end;

function TPzGrid.NextPhoto(P: TPzPhoto; Delta: Integer): TPzPhoto;
var
  fi, k, step: Integer;
  F: TPzFolder;
begin
  Result := nil;
  if P = nil then
    Exit;
  F := P.Folder;
  fi := FShown.IndexOf(F);
  if fi < 0 then
    Exit;
  k := P.Index;
  step := Sign(Delta);
  Delta := Abs(Delta);
  while Delta > 0 do
  begin
    Inc(k, step);
    while (k < 0) or (k >= F.Count) do
    begin
      Inc(fi, step);
      if (fi < 0) or (fi >= FShown.Count) then
        Exit;
      F := TPzFolder(FShown[fi]);
      if step > 0 then k := 0
      else
        k := F.Count - 1;
    end;
    if IsShown(F.Photo(k)) then
      Dec(Delta);
  end;
  Result := F.Photo(k);
end;

procedure TPzGrid.KeyDown(var Key: Word; Shift: TShiftState);
var
  N: TPzPhoto;
begin
  N := nil;
  case Key of
    VK_RIGHT: N := NextPhoto(FSelected, 1);
    VK_LEFT: N := NextPhoto(FSelected, -1);
    VK_DOWN: N := NextPhoto(FSelected, FCols);
    VK_UP: N := NextPhoto(FSelected, -FCols);
    VK_NEXT: SetScrollY(FScrollY + ClientHeight - FCell);
    VK_PRIOR: SetScrollY(FScrollY - ClientHeight + FCell);
    VK_HOME: SetScrollY(0);
    VK_END: SetScrollY(FTotalH);
    VK_RETURN:
      if (FSelected <> nil) and Assigned(FOnOpen) then
        FOnOpen(Self, FSelected);
    VK_A:
      if ssCtrl in Shift then
      begin
        if FSelected <> nil then
          SelectAllInFolder(FSelected.Folder);
      end
      else
      begin
        inherited KeyDown(Key, Shift);
        Exit;
      end;
    else
      inherited KeyDown(Key, Shift);
      Exit;
  end;
  if N <> nil then
  begin
    if ssShift in Shift then
      Select(N, smRange)
    else
      Select(N);
    EnsureVisible(N);
  end;
  Key := 0;
end;

function TPzGrid.VisibleReady(out Total, Ready: Integer): Boolean;
var
  i, k, idx: Integer;
  F: TPzFolder;
  P: TPzPhoto;
  R: TRect;
begin
  Total := 0;
  Ready := 0;
  for i := 0 to FShown.Count - 1 do
  begin
    F := TPzFolder(FShown[i]);
    if F.Top > FScrollY + ClientHeight then
      Break;
    if F.Top + F.Height < FScrollY then
      Continue;
    idx := -1;
    for k := 0 to F.Count - 1 do
    begin
      P := F.Photo(k);
      if not IsShown(P) then
        Continue;
      Inc(idx);
      R := CellRect(F, idx);
      if (R.Bottom <= FScrollY) then
        Continue;
      if R.Top >= FScrollY + ClientHeight then
        Break;
      Inc(Total);
      if P.Failed or ((P.Bmp <> nil) and (P.BmpSize = FThumbSize) and
        (P.BmpEdits = P.EditKey)) then
        Inc(Ready);
    end;
  end;
  Result := Ready = Total;
end;

procedure TPzGrid.ScrollToFolder(F: TPzFolder);
begin
  if F.Visible then
    SetScrollY(F.Top);
end;

procedure TPzGrid.EnsureVisible(P: TPzPhoto);
var
  k, idx: Integer;
  R: TRect;
begin
  if not PhotoVisible(P) then
    Exit;
  idx := 0;
  for k := 0 to P.Index - 1 do
    if IsShown(P.Folder.Photo(k)) then
      Inc(idx);
  R := CellRect(P.Folder, idx);
  if R.Top - CELL_PAD < FScrollY + IfThen(idx < FCols, HEADER_H, 0) then
    SetScrollY(R.Top - CELL_PAD - IfThen(idx < FCols, HEADER_H, 0))
  else if R.Bottom + CELL_PAD > FScrollY + ClientHeight then
    SetScrollY(R.Bottom + CELL_PAD - ClientHeight);
end;

{ TPzViewer }

constructor TPzViewer.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  Color := TColor($161616);
  DoubleBuffered := True;
  TabStop := True;
end;

destructor TPzViewer.Destroy;
begin
  FBmp.Free;
  inherited Destroy;
end;

procedure TPzViewer.SetImage(B: TBitmap);
begin
  FBmp.Free;
  FBmp := B;
  FPlaceholder := nil;
  Invalidate;
end;

procedure TPzViewer.SetPlaceholder(B: TBitmap);
begin
  FreeAndNil(FBmp);
  FPlaceholder := B;
  Invalidate;
end;

procedure TPzViewer.SetMode(M: TPzViewMode);
begin
  FMode := M;
  FHasCrop := False;
  if M = vmPick then
    Cursor := crCross
  else if M = vmCrop then
    Cursor := crCross
  else
    Cursor := crDefault;
  Invalidate;
end;

procedure TPzViewer.SetShowGrid(AValue: Boolean);
begin
  FShowGrid := AValue;
  Invalidate;
end;

function TPzViewer.ImageRect: TRect;
var
  B: TBitmap;
  s: Double;
  w, h: Integer;
begin
  B := FBmp;
  if B = nil then
    B := FPlaceholder;
  if (B = nil) or (B.Width = 0) then
    Exit(Rect(0, 0, 0, 0));
  if FZoom100 and (FBmp <> nil) then
  begin
    w := B.Width;
    h := B.Height;
    Result.Left := (ClientWidth - w) div 2 + FPanX;
    Result.Top := (ClientHeight - h) div 2 + FPanY;
  end
  else
  begin
    s := Min((ClientWidth - 8) / B.Width, (ClientHeight - 8) / B.Height);
    if (FBmp <> nil) and (s > 1) then
      s := 1; // never upscale the real image
    w := Round(B.Width * s);
    h := Round(B.Height * s);
    Result.Left := (ClientWidth - w) div 2;
    Result.Top := (ClientHeight - h) div 2;
  end;
  Result.Right := Result.Left + w;
  Result.Bottom := Result.Top + h;
end;

function TPzViewer.ToImage(X, Y: Integer): TPoint;
var
  R: TRect;
begin
  R := ImageRect;
  if (FBmp = nil) or (R.Right = R.Left) then
    Exit(Point(0, 0));
  Result.X := EnsureRange(Round((X - R.Left) * FBmp.Width / (R.Right - R.Left)),
    0, FBmp.Width);
  Result.Y := EnsureRange(Round((Y - R.Top) * FBmp.Height / (R.Bottom - R.Top)),
    0, FBmp.Height);
end;

procedure TPzViewer.Paint;
var
  C: TCanvas;
  R, CR: TRect;
  B: TBitmap;
  sx, sy: Double;
  gi: Integer;
begin
  C := Canvas;
  C.Brush.Color := Color;
  C.FillRect(ClientRect);
  B := FBmp;
  if B = nil then
    B := FPlaceholder;
  if B <> nil then
  begin
    R := ImageRect;
    if (R.Right - R.Left = B.Width) and (R.Bottom - R.Top = B.Height) then
      C.Draw(R.Left, R.Top, B)
    else
      C.StretchDraw(R, B);
    if FShowGrid then
    begin
      { a fine levelling grid while straightening, as Picasa shows }
      C.Pen.Color := TColor($C8C8C8);
      C.Pen.Style := psDot;
      sx := (R.Right - R.Left) / 12;
      sy := (R.Bottom - R.Top) / 8;
      for gi := 1 to 11 do
        C.Line(R.Left + Round(gi * sx), R.Top, R.Left + Round(gi * sx), R.Bottom);
      for gi := 1 to 7 do
        C.Line(R.Left, R.Top + Round(gi * sy), R.Right, R.Top + Round(gi * sy));
      C.Pen.Style := psSolid;
    end;
    if (FMode = vmCrop) and FHasCrop and (FBmp <> nil) then
    begin
      sx := (R.Right - R.Left) / FBmp.Width;
      sy := (R.Bottom - R.Top) / FBmp.Height;
      CR.Left := R.Left + Round(Min(FCropA.X, FCropB.X) * sx);
      CR.Right := R.Left + Round(Max(FCropA.X, FCropB.X) * sx);
      CR.Top := R.Top + Round(Min(FCropA.Y, FCropB.Y) * sy);
      CR.Bottom := R.Top + Round(Max(FCropA.Y, FCropB.Y) * sy);
      { dim outside the crop }
      C.Brush.Style := bsClear;
      C.Pen.Color := clWhite;
      C.Pen.Width := 2;
      C.Rectangle(CR);
      C.Pen.Width := 1;
      C.Pen.Color := TColor($A0A0A0);
      C.Pen.Style := psDot;
      C.Line(CR.Left + (CR.Right - CR.Left) div 3, CR.Top, CR.Left +
        (CR.Right - CR.Left) div 3, CR.Bottom);
      C.Line(CR.Left + 2 * (CR.Right - CR.Left) div 3, CR.Top, CR.Left +
        2 * (CR.Right - CR.Left) div 3, CR.Bottom);
      C.Line(CR.Left, CR.Top + (CR.Bottom - CR.Top) div 3, CR.Right,
        CR.Top + (CR.Bottom - CR.Top) div 3);
      C.Line(CR.Left, CR.Top + 2 * (CR.Bottom - CR.Top) div 3, CR.Right,
        CR.Top + 2 * (CR.Bottom - CR.Top) div 3);
      C.Pen.Style := psSolid;
      C.Brush.Style := bsSolid;
    end;
  end;
  if FInfo <> '' then
  begin
    C.Font.Color := TColor($A0A0A0);
    C.Font.Height := -12;
    C.Brush.Style := bsClear;
    C.TextOut(8, ClientHeight - 20, FInfo);
    C.Brush.Style := bsSolid;
  end;
end;

procedure TPzViewer.MouseDown(Button: TMouseButton; Shift: TShiftState; X, Y: Integer);
var
  R: TRect;
begin
  inherited MouseDown(Button, Shift, X, Y);
  SetFocus;
  if Button <> mbLeft then
    Exit;
  case FMode of
    vmCrop:
    begin
      FCropA := ToImage(X, Y);
      FCropB := FCropA;
      FHasCrop := True;
      FDragging := True;
    end;
    vmPick:
      if (FBmp <> nil) and Assigned(FOnPick) then
      begin
        R := ImageRect;
        if PtInRect(R, Point(X, Y)) then
          FOnPick(Self, (X - R.Left) / (R.Right - R.Left), (Y - R.Top) /
            (R.Bottom - R.Top));
      end;
    else
      if FZoom100 then
      begin
        FDragging := True;
        FDragStart := Point(X, Y);
        FPanStart := Point(FPanX, FPanY);
        Cursor := crSizeAll;
      end;
  end;
end;

procedure TPzViewer.MouseMove(Shift: TShiftState; X, Y: Integer);
var
  P: TPoint;
  dx, dy: Integer;
begin
  inherited MouseMove(Shift, X, Y);
  if not FDragging then
    Exit;
  if FMode = vmCrop then
  begin
    P := ToImage(X, Y);
    if FCropAspect > 0 then
    begin
      dx := P.X - FCropA.X;
      dy := P.Y - FCropA.Y;
      if Abs(dx) / FCropAspect > Abs(dy) then
        dy := Sign(dy + Ord(dy = 0)) * Round(Abs(dx) / FCropAspect)
      else
        dx := Sign(dx + Ord(dx = 0)) * Round(Abs(dy) * FCropAspect);
      P := Point(FCropA.X + dx, FCropA.Y + dy);
      P.X := EnsureRange(P.X, 0, FBmp.Width);
      P.Y := EnsureRange(P.Y, 0, FBmp.Height);
    end;
    FCropB := P;
    Invalidate;
  end
  else if FZoom100 then
  begin
    FPanX := FPanStart.X + X - FDragStart.X;
    FPanY := FPanStart.Y + Y - FDragStart.Y;
    Invalidate;
  end;
end;

procedure TPzViewer.MouseUp(Button: TMouseButton; Shift: TShiftState; X, Y: Integer);
begin
  inherited MouseUp(Button, Shift, X, Y);
  FDragging := False;
  if FMode = vmNormal then
    Cursor := crDefault;
end;

function TPzViewer.CropRectNorm(out L, T, R, B: Double): Boolean;
begin
  Result := FHasCrop and (FBmp <> nil) and (Abs(FCropA.X - FCropB.X) > 4) and
    (Abs(FCropA.Y - FCropB.Y) > 4);
  if not Result then
    Exit;
  L := Min(FCropA.X, FCropB.X) / FBmp.Width;
  R := Max(FCropA.X, FCropB.X) / FBmp.Width;
  T := Min(FCropA.Y, FCropB.Y) / FBmp.Height;
  B := Max(FCropA.Y, FCropB.Y) / FBmp.Height;
end;

{ TPzStrip }

constructor TPzStrip.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  Color := TColor($1E1E1E);
  DoubleBuffered := True;
  FThumbSize := 160;
end;

function TPzStrip.ItemW: Integer;
begin
  Result := ClientHeight - 8;
end;

procedure TPzStrip.SetCurrent(P: TPzPhoto);
var
  W, X: Integer;
begin
  FCurrent := P;
  if P = nil then
    Exit;
  FFolder := P.Folder;
  W := ItemW + 6;
  X := P.Index * W - FOffset;
  if (X < W) or (X > ClientWidth - 2 * W) then
    FOffset := Max(0, P.Index * W - ClientWidth div 2 + W div 2);
  Invalidate;
end;

procedure TPzStrip.Paint;
var
  C: TCanvas;
  i, X, W, S: Integer;
  P: TPzPhoto;
  R, D: TRect;
  sc: Double;
begin
  C := Canvas;
  C.Brush.Color := Color;
  C.FillRect(ClientRect);
  if FFolder = nil then
    Exit;
  S := ItemW;
  W := S + 6;
  for i := Max(0, FOffset div W) to FFolder.Count - 1 do
  begin
    X := 4 + i * W - FOffset;
    if X > ClientWidth then
      Break;
    P := FFolder.Photo(i);
    R := Rect(X, 4, X + S, 4 + S);
    if P = FCurrent then
    begin
      C.Brush.Color := clPzSel;
      C.FillRect(Rect(R.Left - 3, R.Top - 3, R.Right + 3, R.Bottom + 3));
    end;
    if P.Bmp <> nil then
    begin
      sc := Min(S / P.Bmp.Width, S / P.Bmp.Height);
      D := Rect(0, 0, Round(P.Bmp.Width * sc), Round(P.Bmp.Height * sc));
      OffsetRect(D, R.Left + (S - D.Right) div 2, R.Top + (S - D.Bottom) div 2);
      C.StretchDraw(D, P.Bmp);
    end
    else
    begin
      C.Brush.Color := clPzCell;
      C.FillRect(Rect(R.Left + 6, R.Top + 12, R.Right - 6, R.Bottom - 12));
      if (FLib <> nil) and not P.Failed then
      begin
        P.WantEpoch := FLib.Epoch;
        FLib.RequestThumb(P, FThumbSize);
      end;
    end;
    if P.Star then
      DrawStar(C, R.Left + 8, R.Bottom - 8, 5);
  end;
end;

procedure TPzStrip.MouseDown(Button: TMouseButton; Shift: TShiftState; X, Y: Integer);
var
  i: Integer;
begin
  inherited MouseDown(Button, Shift, X, Y);
  if FFolder = nil then
    Exit;
  i := (X - 4 + FOffset) div (ItemW + 6);
  if (i >= 0) and (i < FFolder.Count) and Assigned(FOnPick) then
    FOnPick(Self, FFolder.Photo(i));
end;

function TPzStrip.DoMouseWheel(Shift: TShiftState; WheelDelta: Integer;
  MousePos: TPoint): Boolean;
begin
  if FFolder <> nil then
    FOffset := EnsureRange(FOffset - WheelDelta, 0,
      Max(0, FFolder.Count * (ItemW + 6) - ClientWidth));
  Invalidate;
  Result := True;
end;

{ TPzTray }

constructor TPzTray.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  FPhotos := TList.Create;
  Color := TColor($242424);
  DoubleBuffered := True;
  FThumbSize := 160;
end;

destructor TPzTray.Destroy;
begin
  FPhotos.Free;
  inherited Destroy;
end;

function TPzTray.ItemW: Integer;
begin
  Result := ClientHeight - 10;
end;

procedure TPzTray.SetPhotos(L: TList);
begin
  FPhotos.Assign(L);
  FOffset := EnsureRange(FOffset, 0, Max(0, FPhotos.Count * (ItemW + 4) - ClientWidth));
  Invalidate;
end;

procedure TPzTray.Paint;
var
  C: TCanvas;
  i, X, S: Integer;
  P: TPzPhoto;
  R, D: TRect;
  sc: Double;
begin
  C := Canvas;
  C.Brush.Color := Color;
  C.FillRect(ClientRect);
  S := ItemW;
  if FPhotos.Count = 0 then
  begin
    C.Font.Color := TColor($707070);
    C.Font.Height := -14;
    C.Brush.Style := bsClear;
    C.TextOut((ClientWidth - C.TextWidth('Selection')) div 2,
      (ClientHeight - 16) div 2, 'Selection');
    C.Brush.Style := bsSolid;
    Exit;
  end;
  for i := Max(0, FOffset div (S + 4)) to FPhotos.Count - 1 do
  begin
    X := 5 + i * (S + 4) - FOffset;
    if X > ClientWidth then
      Break;
    P := TPzPhoto(FPhotos[i]);
    R := Rect(X, 5, X + S, 5 + S);
    if P.Bmp <> nil then
    begin
      sc := Min(S / P.Bmp.Width, S / P.Bmp.Height);
      D := Rect(0, 0, Round(P.Bmp.Width * sc), Round(P.Bmp.Height * sc));
      OffsetRect(D, R.Left + (S - D.Right) div 2, R.Top + (S - D.Bottom) div 2);
      C.StretchDraw(D, P.Bmp);
    end
    else
    begin
      C.Brush.Color := clPzCell;
      C.FillRect(Rect(R.Left + 4, R.Top + 10, R.Right - 4, R.Bottom - 10));
      if (FLib <> nil) and not P.Failed then
      begin
        P.WantEpoch := FLib.Epoch;
        FLib.RequestThumb(P, FThumbSize);
      end;
    end;
    if P.Held then
    begin
      { held: a green corner mark, like Picasa's pin }
      C.Brush.Color := TColor($50C850);
      C.Pen.Color := TColor($202020);
      C.Ellipse(R.Right - 12, R.Top + 2, R.Right - 2, R.Top + 12);
    end;
    if P.Star then
      DrawStar(C, R.Left + 8, R.Bottom - 8, 5);
  end;
end;

procedure TPzTray.MouseDown(Button: TMouseButton; Shift: TShiftState; X, Y: Integer);
var
  i: Integer;
begin
  inherited MouseDown(Button, Shift, X, Y);
  i := (X - 5 + FOffset) div (ItemW + 4);
  if (i >= 0) and (i < FPhotos.Count) and Assigned(FOnPick) then
    FOnPick(Self, TPzPhoto(FPhotos[i]));
end;

function TPzTray.DoMouseWheel(Shift: TShiftState; WheelDelta: Integer;
  MousePos: TPoint): Boolean;
begin
  FOffset := EnsureRange(FOffset - WheelDelta, 0,
    Max(0, FPhotos.Count * (ItemW + 4) - ClientWidth));
  Invalidate;
  Result := True;
end;

{ TPzHistogram }

constructor TPzHistogram.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  FLines := TStringList.Create;
  Color := TColor($262626);
  DoubleBuffered := True;
end;

destructor TPzHistogram.Destroy;
begin
  FLines.Free;
  inherited Destroy;
end;

procedure TPzHistogram.SetHistogram(const H: Tpz_hist);
begin
  FHist := H;
  FHave := True;
  Invalidate;
end;

procedure TPzHistogram.Clear;
begin
  FHave := False;
  FLines.Clear;
  Invalidate;
end;

procedure TPzHistogram.Paint;
const
  Cols: array[0..2] of TColor = (TColor($F07850), TColor($50C850), TColor($5050F0));
  // B, G, R
var
  C: TCanvas;
  R: TRect;
  i, ch, x, h, mx, Y: Integer;
  Pts: array[0..257] of TPoint;
begin
  C := Canvas;
  C.Brush.Color := Color;
  C.FillRect(ClientRect);
  C.Font.Height := -12;
  C.Font.Style := [fsBold];
  C.Font.Color := clPzHeader;
  C.Brush.Style := bsClear;
  C.TextOut(8, 4, 'Histogram & Camera Information');
  C.Font.Style := [];
  R := Rect(8, 24, ClientWidth - 8, 24 + 64);
  C.Pen.Color := TColor($444444);
  C.Brush.Style := bsClear;
  C.Rectangle(R);
  if FHave then
  begin
    mx := 1;
    for ch := 0 to 2 do
      for i := 2 to 253 do // ignore clipped ends when scaling
        mx := Max(mx, FHist[ch][i]);
    for ch := 2 downto 0 do
    begin
      for i := 0 to 255 do
      begin
        x := R.Left + 1 + i * (R.Right - R.Left - 2) div 255;
        h := Min(R.Bottom - R.Top - 2, Round(FHist[ch][i] / mx *
          (R.Bottom - R.Top - 2)));
        Pts[i] := Point(x, R.Bottom - 1 - h);
      end;
      Pts[256] := Point(R.Right - 1, R.Bottom - 1);
      Pts[257] := Point(R.Left + 1, R.Bottom - 1);
      C.Pen.Color := Cols[ch];
      C.Brush.Style := bsClear;
      C.Polyline(Pts, 0, 256);
    end;
  end;
  C.Font.Color := TColor($C8C8C8);
  C.Font.Height := -11;
  Y := R.Bottom + 6;
  for i := 0 to FLines.Count - 1 do
  begin
    C.TextOut(8, Y, FLines[i]);
    Inc(Y, 15);
  end;
  C.Brush.Style := bsSolid;
end;

end.
