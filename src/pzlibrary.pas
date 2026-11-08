{ Photo library model, SQLite thumbnail cache, folder scanner and the
  decoding worker pool.

  Threading model
  - The main thread owns the model (folders, photos, bitmaps) and the UI.
  - Workers decode images and generate thumbnails; they only read the few
    photo fields copied into a job, and hand back plain BGRA buffers.
  - A single SQLite write connection is shared under a lock; generated
    thumbnails are committed in batches. Each worker has its own read
    connection (WAL mode, so readers never block the writer). }
unit pzlibrary;

{$mode objfpc}{$H+}
{$modeswitch advancedrecords}

interface

uses
  Classes, SysUtils, SyncObjs, Graphics, ctypes, sqlite3, BaseUnix, Unix, Linux,
  pzcorebind, pzini, pzrender;

const
  THUMB_STORE = 320;   // long edge of cached thumbnails
  THUMB_QUALITY = 82;

type
  TPzFolder = class;

  { TPzPhoto }

  TPzPhoto = class
  public
    Folder: TPzFolder;
    Id: Int64;
    Name: string;
    Size, MTime: Int64;
    W, H: Integer;       // upright full-resolution size (0 = unknown)
    Taken: Int64;        // seconds since epoch, local wall time
    Fmt: Integer;
    IsRaw: Boolean;
    Camera: string;
    HasThumb: Boolean;   // a cached thumbnail exists in the DB
    { edits, mirrored from .picasa.ini }
    Star: Boolean;
    Filters: string;
    Redo: string;
    Rotate: Integer;
    { display cache, main thread only }
    Bmp: TBitmap;
    BmpSize: Integer;
    BmpEdits: string;    // Filters+Rotate the bitmap was rendered with
    BmpPending: Boolean; // set by main, cleared by worker when dropped
    WantEpoch: Integer;  // last paint that needed this bitmap
    LruStamp: Int64;
    Index: Integer;      // index inside folder
    Failed: Boolean;
    ViewPending: Boolean;
    destructor Destroy; override;
    function Path: string;
    function EditKey: string;
    function HasEdits: Boolean;
  end;

  { TPzFolder }

  TPzFolder = class
  public
    Id: Int64;
    Path: string;
    Name: string;
    SortDate: Int64;
    DirMTime: Int64;
    Photos: TList;
    Ini: TPzIni;
    IniLoaded: Boolean;
    { layout, owned by the grid }
    Top, Height: Integer;
    Visible: Boolean;
    constructor Create;
    destructor Destroy; override;
    function Photo(i: Integer): TPzPhoto; inline;
    function Count: Integer; inline;
    procedure EnsureIni;
    procedure SavePhotoEdits(P: TPzPhoto);
    procedure FlushIni;
  end;

  TPzJobKind = (jkThumb, jkGen, jkView);

  TPzJob = class
    Kind: TPzJobKind;
    Photo: TPzPhoto;
    Path: string;
    PhotoId: Int64;
    HasThumb: Boolean;
    Edits: string;       // chain string, '' = none
    Rotate: Integer;
    Size: Integer;       // thumb box
    MaxW, MaxH, Flags: Integer;
    Token: Integer;
    Epoch: Integer;
  end;

  TPzResult = class
    Kind: TPzJobKind;
    Photo: TPzPhoto;
    Img: Tpz_image;
    Meta: Tpz_meta;
    HaveMeta: Boolean;
    Size: Integer;
    Edits: string;
    Rotate: Integer;
    Flags: Integer;
    Token: Integer;
    OK: Boolean;
    Seconds: Double;
    destructor Destroy; override;
  end;

  TPzResultEvent = procedure(R: TPzResult) of object;

  TPzLibrary = class;

  TPzWorker = class(TThread)
  private
    FLib: TPzLibrary;
    FDB: psqlite3;
    FSelThumb: psqlite3_stmt;
    function ReadThumb(Id: Int64; out Img: Tpz_image): Boolean;
    procedure DoJob(J: TPzJob);
  protected
    procedure Execute; override;
  public
    constructor Create(ALib: TPzLibrary);
  end;

  TPzScanEntry = record
    Name: string;
    Size, MTime: Int64;
  end;

  TPzScanDir = class
    Path: string;
    DirMTime: Int64;
    Entries: array of TPzScanEntry;
    Unchanged: Boolean;
  end;

  TPzScanner = class(TThread)
  private
    FLib: TPzLibrary;
    FRoots: TStringList;
    FKnown: TStringList;   // path=mtime of folders already in the DB
    procedure ScanDir(const Dir: string; Depth: Integer);
  protected
    procedure Execute; override;
  public
    constructor Create(ALib: TPzLibrary; ARoots, AKnown: TStrings);
    destructor Destroy; override;
  end;

  TPendingThumb = record
    Id: Int64;
    Data: TBytes;
    W, H: Integer;
    Taken: Int64;
    Fmt: Integer;
    Camera: string;
  end;

  { TPzLibrary }

  TPzLibrary = class
  private
    FDBPath: string;
    FDB: psqlite3;              // main/write connection
    FDBLock: TCriticalSection;
    FPending: array of TPendingThumb;
    FQLock: TCriticalSection;
    FQEvent: TEvent;
    FViewQ, FThumbQ, FGenQ: TList;
    FResults: TList;
    FDeliverQueued: Boolean;
    FWorkers: array of TPzWorker;
    FScanner: TPzScanner;
    FScanResults: TList;
    FTerminating: Boolean;
    FGenActive, FGenLimit: Integer;
    FOnResult: TPzResultEvent;
    FOnScanDir: TNotifyEvent;
    FOnScanDone: TNotifyEvent;
    FFolderById: TList;
    procedure Exec(const SQL: string);
    procedure DeliverResults;
    procedure DeliverScan;
    function PopJob(out J: TPzJob): Boolean;
    procedure PostResult(R: TPzResult);
    procedure QueueThumbWrite(const T: TPendingThumb);
    procedure FlushPendingLocked;
    procedure ApplyScanDir(D: TPzScanDir);
  public
    Folders: TList;
    Roots: TStringList;
    Epoch: Integer;
    ScanBusy: Boolean;
    GenTotal, GenDone: Integer;
    constructor Create(const ADBPath: string);
    destructor Destroy; override;
    procedure LoadFromDB;
    procedure StartWorkers(N: Integer);
    procedure StartScan;
    procedure Shutdown;
    procedure SortFolders;
    procedure RequestThumb(P: TPzPhoto; ASize: Integer);
    procedure RequestView(P: TPzPhoto; MaxW, MaxH, Flags, Token: Integer;
      Front: Boolean);
    procedure QueueBackgroundGen;
    procedure CancelViews(KeepToken: Integer);
    procedure FlushPending;
    function PendingJobs: Integer;
    procedure AddRoot(const Dir: string);
    property OnResult: TPzResultEvent read FOnResult write FOnResult;
    property OnScanDir: TNotifyEvent read FOnScanDir write FOnScanDir;
    property OnScanDone: TNotifyEvent read FOnScanDone write FOnScanDone;
  end;

var
  PzIniReadOnly: Boolean = False;

function IsImageFile(const Name: string): Boolean;
function NowSeconds: Double;
function PzCPUCount: Integer;
function FormatFromExt(const Name: string): Integer;
function FolderDateFromName(const Name: string; Fallback: Int64): Int64;
function FormatTaken(T: Int64): string;

implementation

uses
  DateUtils, Math;

var
  PZ_TRANSIENT: sqlite3_destructor_type;

const
  ImageExts: array[0..33] of string =
    ('jpg', 'jpeg', 'jpe', 'png', 'gif', 'webp', 'heic', 'heif', 'avif',
    'dng', 'pef', 'cr2', 'cr3', 'crw', 'nef', 'nrw', 'arw', 'srf',
    'sr2', 'orf', 'rw2', 'raf', 'raw',
    'rwl', 'srw', 'x3f', '3fr', 'iiq', 'mos', 'mrw', 'kdc', 'dcr', 'erf', 'mef');

function IsImageFile(const Name: string): Boolean;
var
  E: string;
  i: Integer;
begin
  E := LowerCase(ExtractFileExt(Name));
  if (E = '') or (Name[1] = '.') then
    Exit(False);
  Delete(E, 1, 1);
  for i := Low(ImageExts) to High(ImageExts) do
    if E = ImageExts[i] then
      Exit(True);
  Result := False;
end;

function NowSeconds: Double;
var
  tp: TTimeSpec;
begin
  clock_gettime(CLOCK_MONOTONIC, @tp);
  Result := tp.tv_sec + tp.tv_nsec * 1e-9;
end;

function sysconf(name: cint): clong; cdecl; external 'c';

function PzCPUCount: Integer;
const
  _SC_NPROCESSORS_ONLN = 84;
begin
  Result := sysconf(_SC_NPROCESSORS_ONLN);
  if Result < 1 then
    Result := 4;
end;

{ format guess from the extension: scanning must not open every file }
function FormatFromExt(const Name: string): Integer;
var
  E: string;
begin
  E := LowerCase(ExtractFileExt(Name));
  case E of
    '.jpg', '.jpeg', '.jpe': Result := PZ_FMT_JPEG;
    '.png': Result := PZ_FMT_PNG;
    '.gif': Result := PZ_FMT_GIF;
    '.webp': Result := PZ_FMT_WEBP;
    '.heic', '.heif', '.avif': Result := PZ_FMT_TIFF;
    else
      Result := PZ_FMT_RAW;
  end;
end;

{ folder names like 20221016_HornPond -> that date }
function FolderDateFromName(const Name: string; Fallback: Int64): Int64;
var
  Y, M, D: Integer;
begin
  Result := Fallback;
  if (Length(Name) >= 8) and (Name[1] in ['1', '2']) then
  begin
    Y := StrToIntDef(Copy(Name, 1, 4), 0);
    M := StrToIntDef(Copy(Name, 5, 2), 0);
    D := StrToIntDef(Copy(Name, 7, 2), 0);
    if (Y > 1900) and (M in [1..12]) and (D in [1..31]) then
      Result := DateTimeToUnix(EncodeDate(Y, M, Min(D, DaysInAMonth(Y, M))));
  end;
end;

function FormatTaken(T: Int64): string;
begin
  if T <= 0 then
    Result := ''
  else
    Result := FormatDateTime('yyyy-mm-dd hh:nn:ss', UnixToDateTime(T));
end;

{ TPzPhoto }

destructor TPzPhoto.Destroy;
begin
  Bmp.Free;
  inherited Destroy;
end;

function TPzPhoto.Path: string;
begin
  Result := Folder.Path + '/' + Name;
end;

function TPzPhoto.EditKey: string;
begin
  Result := Filters + '|' + IntToStr(Rotate);
end;

function TPzPhoto.HasEdits: Boolean;
begin
  Result := (Filters <> '') or (Rotate <> 0);
end;

{ TPzFolder }

constructor TPzFolder.Create;
begin
  Photos := TList.Create;
end;

destructor TPzFolder.Destroy;
var
  i: Integer;
begin
  FlushIni;
  for i := 0 to Photos.Count - 1 do
    TPzPhoto(Photos[i]).Free;
  Photos.Free;
  Ini.Free;
  inherited Destroy;
end;

function TPzFolder.Photo(i: Integer): TPzPhoto;
begin
  Result := TPzPhoto(Photos[i]);
end;

function TPzFolder.Count: Integer;
begin
  Result := Photos.Count;
end;

procedure TPzFolder.EnsureIni;
var
  i: Integer;
  P: TPzPhoto;
begin
  if IniLoaded then
    Exit;
  IniLoaded := True;
  Ini := TPzIni.Create(Path + '/.picasa.ini');
  Ini.Load;
  for i := 0 to Count - 1 do
  begin
    P := Photo(i);
    P.Star := Ini.ReadValue(P.Name, 'star') = 'yes';
    P.Filters := Ini.ReadValue(P.Name, 'filters');
    P.Redo := Ini.ReadValue(P.Name, 'redo');
    P.Rotate := ParseRotate(Ini.ReadValue(P.Name, 'rotate'));
  end;
end;

procedure TPzFolder.SavePhotoEdits(P: TPzPhoto);
begin
  EnsureIni;
  if P.Star then
    Ini.WriteValue(P.Name, 'star', 'yes')
  else
    Ini.DeleteKey(P.Name, 'star');
  Ini.WriteValue(P.Name, 'filters', P.Filters);
  Ini.WriteValue(P.Name, 'redo', P.Redo);
  Ini.WriteValue(P.Name, 'rotate', RotateToString(P.Rotate));
end;

procedure TPzFolder.FlushIni;
begin
  if PzIniReadOnly then
    Exit;
  if (Ini <> nil) and Ini.Dirty then
    Ini.Save;
end;

{ TPzResult }

destructor TPzResult.Destroy;
begin
  pz_free(@Img);
  inherited Destroy;
end;

{ TPzWorker }

constructor TPzWorker.Create(ALib: TPzLibrary);
begin
  FLib := ALib;
  FreeOnTerminate := False;
  inherited Create(False);
end;

function TPzWorker.ReadThumb(Id: Int64; out Img: Tpz_image): Boolean;
var
  P: Pointer;
  N: Integer;
begin
  Result := False;
  PzInit(Img);
  if FSelThumb = nil then
    Exit;
  sqlite3_reset(FSelThumb);
  sqlite3_bind_int64(FSelThumb, 1, Id);
  if sqlite3_step(FSelThumb) = SQLITE_ROW then
  begin
    P := sqlite3_column_blob(FSelThumb, 0);
    N := sqlite3_column_bytes(FSelThumb, 0);
    if (P <> nil) and (N > 0) then
      Result := pz_decode_jpeg_mem(P, N, 0, 0, 0, @Img) >= 0;
  end;
  sqlite3_reset(FSelThumb);
end;

procedure TPzWorker.DoJob(J: TPzJob);
var
  R: TPzResult;
  T0: Double;
  rc: Integer;
  Img, Tmp: Tpz_image;
  Buf: PByte;
  Len: culong;
  PT: TPendingThumb;
  s: Double;
  Chain: TPzChain;
begin
  T0 := NowSeconds;
  R := TPzResult.Create;
  R.Kind := J.Kind;
  R.Photo := J.Photo;
  R.Size := J.Size;
  R.Edits := J.Edits;
  R.Rotate := J.Rotate;
  R.Flags := J.Flags;
  R.Token := J.Token;
  PzInit(R.Img);
  try
    if J.Kind = jkView then
    begin
      rc := pz_load(PAnsiChar(J.Path), J.MaxW, J.MaxH, J.Flags, @R.Img, @R.Meta);
      R.OK := rc >= 0;
      R.HaveMeta := R.OK;
    end
    else
    begin
      { thumbnail: cached blob or generate from the file }
      PzInit(Img);
      if not (J.HasThumb and ReadThumb(J.PhotoId, Img)) then
      begin
        rc := pz_load(PAnsiChar(J.Path), THUMB_STORE, THUMB_STORE,
          PZ_THUMB, @Img, @R.Meta);
        if rc >= 0 then
        begin
          R.HaveMeta := True;
          Buf := nil;
          if pz_encode_jpeg_mem(@Img, THUMB_QUALITY, @Buf, @Len) = 0 then
          begin
            PT.Id := J.PhotoId;
            SetLength(PT.Data, Len);
            Move(Buf^, PT.Data[0], Len);
            pz_free_mem(Buf);
            PT.W := R.Meta.width;
            PT.H := R.Meta.height;
            PT.Taken := R.Meta.taken;
            PT.Fmt := R.Meta.format;
            PT.Camera := PzMake(R.Meta);
            FLib.QueueThumbWrite(PT);
          end;
        end
        else
          PzInit(Img);
      end;
      R.OK := Img.px <> nil;
      if R.OK and (J.Kind = jkThumb) then
      begin
        if (J.Edits <> '') or (J.Rotate <> 0) then
        begin
          Chain := ParseChain(J.Edits);
          RenderChain(Img, Chain, J.Rotate);
        end;
        s := Min(J.Size / Img.w, J.Size / Img.h);
        if s < 1 then
        begin
          pz_resize(@Img, Max(1, Round(Img.w * s)), Max(1, Round(Img.h * s)), @Tmp);
          pz_free(@Img);
          Img := Tmp;
        end;
        R.Img := Img;
      end
      else
        pz_free(@Img);
    end;
  except
    R.OK := False;
  end;
  R.Seconds := NowSeconds - T0;
  { always report, failures too: the UI counts progress and marks the
    photo as failed so it is not retried every time }
  FLib.PostResult(R);
end;

procedure TPzWorker.Execute;
var
  J: TPzJob;
begin
  if sqlite3_open_v2(PAnsiChar(FLib.FDBPath), @FDB, SQLITE_OPEN_READONLY or
    SQLITE_OPEN_NOMUTEX, nil) = SQLITE_OK then
  begin
    sqlite3_busy_timeout(FDB, 5000);
    sqlite3_prepare_v2(FDB, 'SELECT data FROM thumbs WHERE id=?', -1, @FSelThumb, nil);
  end;
  while not Terminated do
  begin
    if FLib.PopJob(J) then
    begin
      try
        DoJob(J);
      finally
        if J.Kind = jkGen then
          InterlockedDecrement(FLib.FGenActive);
        J.Free;
      end;
    end
    else
    begin
      FLib.FlushPending; // idle: commit generated thumbnails
      FLib.FQEvent.WaitFor(200);
    end;
  end;
  if FSelThumb <> nil then
    sqlite3_finalize(FSelThumb);
  if FDB <> nil then
    sqlite3_close(FDB);
end;

{ TPzScanner }

constructor TPzScanner.Create(ALib: TPzLibrary; ARoots, AKnown: TStrings);
begin
  FLib := ALib;
  FRoots := TStringList.Create;
  FRoots.Assign(ARoots);
  FKnown := TStringList.Create;
  FKnown.Assign(AKnown);
  FKnown.Sorted := True;
  FreeOnTerminate := False;
  inherited Create(False);
end;

destructor TPzScanner.Destroy;
begin
  FRoots.Free;
  FKnown.Free;
  inherited Destroy;
end;

procedure TPzScanner.ScanDir(const Dir: string; Depth: Integer);
var
  D: pDir;
  E: pDirent;
  Nm, Full: string;
  St: Stat;
  SubDirs: TStringList;
  Files: TStringList;
  SD: TPzScanDir;
  i, k: Integer;
  DirSt: Stat;
  IsDir, IsReg: Boolean;
  Known: string;
begin
  if Terminated or (Depth > 12) then
    Exit;
  if fpStat(Dir, DirSt) <> 0 then
    Exit;
  D := fpOpenDir(Dir);
  if D = nil then
    Exit;
  SubDirs := TStringList.Create;
  Files := TStringList.Create;
  try
    repeat
      E := fpReadDir(D^);
      if E = nil then
        Break;
      Nm := StrPas(PChar(@E^.d_name[0]));
      if (Nm = '') or (Nm[1] = '.') then
        Continue; // hidden: .picasaoriginals, .thumbnails, ...
      IsDir := E^.d_type = 4;
      IsReg := E^.d_type = 8;
      if (E^.d_type = 0) or (E^.d_type = 10) then
      begin
        if fpStat(Dir + '/' + Nm, St) = 0 then
        begin
          IsDir := fpS_ISDIR(St.st_mode);
          IsReg := fpS_ISREG(St.st_mode);
        end;
      end;
      if IsDir then
      begin
        if (LowerCase(Nm) <> 'picasa2') and (LowerCase(Nm) <> 'picasa2albums') then
          SubDirs.Add(Nm);
      end
      else if IsReg and IsImageFile(Nm) then
        Files.Add(Nm);
    until False;
    fpCloseDir(D^);
    if Files.Count > 0 then
    begin
      SD := TPzScanDir.Create;
      SD.Path := Dir;
      SD.DirMTime := DirSt.st_mtime;
      k := FKnown.IndexOfName(Dir);
      Known := '';
      if k >= 0 then
        Known := FKnown.ValueFromIndex[k];
      if Known = IntToStr(SD.DirMTime) then
        SD.Unchanged := True
      else
      begin
        Files.Sort;
        SetLength(SD.Entries, Files.Count);
        for i := 0 to Files.Count - 1 do
        begin
          SD.Entries[i].Name := Files[i];
          if fpStat(Dir + '/' + Files[i], St) = 0 then
          begin
            SD.Entries[i].Size := St.st_size;
            SD.Entries[i].MTime := St.st_mtime;
          end;
        end;
      end;
      FLib.FQLock.Enter;
      FLib.FScanResults.Add(SD);
      FLib.FQLock.Leave;
      TThread.Queue(nil, @FLib.DeliverScan);
    end;
    SubDirs.Sort;
    for i := 0 to SubDirs.Count - 1 do
    begin
      Full := Dir + '/' + SubDirs[i];
      ScanDir(Full, Depth + 1);
    end;
  finally
    SubDirs.Free;
    Files.Free;
  end;
end;

procedure TPzScanner.Execute;
var
  i: Integer;
begin
  for i := 0 to FRoots.Count - 1 do
    ScanDir(ExcludeTrailingPathDelimiter(FRoots[i]), 0);
  if not Terminated then
    TThread.Queue(nil, @FLib.DeliverScan);
end;

{ TPzLibrary }

constructor TPzLibrary.Create(const ADBPath: string);
begin
  FDBPath := ADBPath;
  FDBLock := TCriticalSection.Create;
  FQLock := TCriticalSection.Create;
  FQEvent := TEvent.Create(nil, False, False, '');
  FViewQ := TList.Create;
  FThumbQ := TList.Create;
  FGenQ := TList.Create;
  FResults := TList.Create;
  FScanResults := TList.Create;
  Folders := TList.Create;
  FFolderById := TList.Create;
  Roots := TStringList.Create;
  FGenLimit := 6;
  ForceDirectories(ExtractFileDir(ADBPath));
  if sqlite3_open_v2(PAnsiChar(ADBPath), @FDB, SQLITE_OPEN_READWRITE or
    SQLITE_OPEN_CREATE or SQLITE_OPEN_FULLMUTEX, nil) <> SQLITE_OK then
    raise Exception.Create('cannot open thumbnail database ' + ADBPath);
  sqlite3_busy_timeout(FDB, 5000);
  Exec('PRAGMA journal_mode=WAL');
  Exec('PRAGMA synchronous=NORMAL');
  Exec('PRAGMA cache_size=-65536');
  Exec('CREATE TABLE IF NOT EXISTS folders(id INTEGER PRIMARY KEY, path TEXT UNIQUE, mtime INTEGER)');
  Exec('CREATE TABLE IF NOT EXISTS photos(id INTEGER PRIMARY KEY, folder INTEGER, name TEXT, size INTEGER, '
    + 'mtime INTEGER, w INTEGER, h INTEGER, taken INTEGER, fmt INTEGER, camera TEXT, UNIQUE(folder,name))');
  Exec('CREATE TABLE IF NOT EXISTS thumbs(id INTEGER PRIMARY KEY, data BLOB)');
end;

destructor TPzLibrary.Destroy;
var
  i: Integer;
begin
  Shutdown;
  FlushPending;
  for i := 0 to Folders.Count - 1 do
    TPzFolder(Folders[i]).Free;
  Folders.Free;
  FFolderById.Free;
  for i := 0 to FViewQ.Count - 1 do TPzJob(FViewQ[i]).Free;
  for i := 0 to FThumbQ.Count - 1 do TPzJob(FThumbQ[i]).Free;
  for i := 0 to FGenQ.Count - 1 do TPzJob(FGenQ[i]).Free;
  for i := 0 to FResults.Count - 1 do TPzResult(FResults[i]).Free;
  for i := 0 to FScanResults.Count - 1 do TPzScanDir(FScanResults[i]).Free;
  FViewQ.Free;
  FThumbQ.Free;
  FGenQ.Free;
  FResults.Free;
  FScanResults.Free;
  Roots.Free;
  if FDB <> nil then
    sqlite3_close(FDB);
  FQEvent.Free;
  FQLock.Free;
  FDBLock.Free;
  inherited Destroy;
end;

procedure TPzLibrary.Exec(const SQL: string);
begin
  sqlite3_exec(FDB, PAnsiChar(SQL), nil, nil, nil);
end;

procedure TPzLibrary.AddRoot(const Dir: string);
begin
  if Roots.IndexOf(Dir) < 0 then
    Roots.Add(Dir);
end;

function InRoots(const Path: string; Roots: TStrings): Boolean;
var
  i: Integer;
  R: string;
begin
  for i := 0 to Roots.Count - 1 do
  begin
    R := ExcludeTrailingPathDelimiter(Roots[i]);
    if (Path = R) or (Copy(Path, 1, Length(R) + 1) = R + '/') then
      Exit(True);
  end;
  Result := False;
end;

procedure TPzLibrary.LoadFromDB;
var
  St: psqlite3_stmt;
  F: TPzFolder;
  P: TPzPhoto;
  Id: Int64;
  Idx: TList;
  Map: TStringList;
  i: Integer;
  HasT: array of Boolean;
  MaxId: Int64;
begin
  Map := TStringList.Create;
  Idx := TList.Create;
  try
    { folders }
    if sqlite3_prepare_v2(FDB, 'SELECT id,path,mtime FROM folders', -1, @St, nil) =
      SQLITE_OK then
    begin
      while sqlite3_step(St) = SQLITE_ROW do
      begin
        F := TPzFolder.Create;
        F.Id := sqlite3_column_int64(St, 0);
        F.Path := StrPas(sqlite3_column_text(St, 1));
        F.DirMTime := sqlite3_column_int64(St, 2);
        if not InRoots(F.Path, Roots) then
        begin
          F.Free;
          Continue;
        end;
        F.Name := ExtractFileName(F.Path);
        F.SortDate := FolderDateFromName(F.Name, F.DirMTime);
        Folders.Add(F);
        while FFolderById.Count <= F.Id do
          FFolderById.Add(nil);
        FFolderById[F.Id] := F;
      end;
      sqlite3_finalize(St);
    end;
    { which photos have thumbnails: one compact scan of the rowid b-tree }
    MaxId := 0;
    if sqlite3_prepare_v2(FDB, 'SELECT max(id) FROM photos', -1, @St, nil) =
      SQLITE_OK then
    begin
      if sqlite3_step(St) = SQLITE_ROW then
        MaxId := sqlite3_column_int64(St, 0);
      sqlite3_finalize(St);
    end;
    SetLength(HasT, MaxId + 1);
    if sqlite3_prepare_v2(FDB, 'SELECT id FROM thumbs', -1, @St, nil) = SQLITE_OK then
    begin
      while sqlite3_step(St) = SQLITE_ROW do
      begin
        Id := sqlite3_column_int64(St, 0);
        if (Id >= 0) and (Id <= MaxId) then
          HasT[Id] := True;
      end;
      sqlite3_finalize(St);
    end;
    { photos, already in display order }
    if sqlite3_prepare_v2(FDB,
      'SELECT id,folder,name,size,mtime,w,h,taken,fmt,camera FROM photos ORDER BY folder,name',
      -1, @St, nil) = SQLITE_OK then
    begin
      while sqlite3_step(St) = SQLITE_ROW do
      begin
        Id := sqlite3_column_int64(St, 1);
        if (Id < 0) or (Id >= FFolderById.Count) or (FFolderById[Id] = nil) then
          Continue;
        F := TPzFolder(FFolderById[Id]);
        P := TPzPhoto.Create;
        P.Folder := F;
        P.Id := sqlite3_column_int64(St, 0);
        P.Name := StrPas(sqlite3_column_text(St, 2));
        P.Size := sqlite3_column_int64(St, 3);
        P.MTime := sqlite3_column_int64(St, 4);
        P.W := sqlite3_column_int(St, 5);
        P.H := sqlite3_column_int(St, 6);
        P.Taken := sqlite3_column_int64(St, 7);
        P.Fmt := sqlite3_column_int(St, 8);
        P.IsRaw := P.Fmt = PZ_FMT_RAW;
        P.Camera := StrPas(sqlite3_column_text(St, 9));
        P.HasThumb := (P.Id <= MaxId) and HasT[P.Id];
        P.Index := F.Photos.Count;
        F.Photos.Add(P);
      end;
      sqlite3_finalize(St);
    end;
    { drop empty folders }
    for i := Folders.Count - 1 downto 0 do
      if TPzFolder(Folders[i]).Count = 0 then
      begin
        FFolderById[TPzFolder(Folders[i]).Id] := nil;
        TPzFolder(Folders[i]).Free;
        Folders.Delete(i);
      end;
    SortFolders;
  finally
    Map.Free;
    Idx.Free;
  end;
end;

function CompareFolders(A, B: Pointer): Integer;
var
  FA, FB: TPzFolder;
begin
  FA := TPzFolder(A);
  FB := TPzFolder(B);
  { newest first, like Picasa's default library view }
  if FA.SortDate > FB.SortDate then Result := -1
  else if FA.SortDate < FB.SortDate then Result := 1
  else
    Result := -CompareStr(FA.Name, FB.Name);
end;

procedure TPzLibrary.SortFolders;
begin
  Folders.Sort(@CompareFolders);
end;

procedure TPzLibrary.StartWorkers(N: Integer);
var
  i: Integer;
begin
  if N < 1 then
    N := 1;
  pz_set_threads(Max(1, N div 2));
  SetLength(FWorkers, N);
  for i := 0 to N - 1 do
    FWorkers[i] := TPzWorker.Create(Self);
end;

procedure TPzLibrary.StartScan;
var
  Known: TStringList;
  i: Integer;
begin
  if FScanner <> nil then
    Exit;
  Known := TStringList.Create;
  try
    for i := 0 to Folders.Count - 1 do
      Known.Add(TPzFolder(Folders[i]).Path + '=' +
        IntToStr(TPzFolder(Folders[i]).DirMTime));
    ScanBusy := True;
    FScanner := TPzScanner.Create(Self, Roots, Known);
  finally
    Known.Free;
  end;
end;

procedure TPzLibrary.Shutdown;
var
  i: Integer;
begin
  if FTerminating then
    Exit;
  FTerminating := True;
  if FScanner <> nil then
  begin
    FScanner.Terminate;
    FScanner.WaitFor;
    FreeAndNil(FScanner);
  end;
  for i := 0 to High(FWorkers) do
    FWorkers[i].Terminate;
  for i := 0 to High(FWorkers) do
    FQEvent.SetEvent;
  for i := 0 to High(FWorkers) do
  begin
    FQEvent.SetEvent;
    FWorkers[i].WaitFor;
    FWorkers[i].Free;
  end;
  SetLength(FWorkers, 0);
  CheckSynchronize(0);
end;

function TPzLibrary.PopJob(out J: TPzJob): Boolean;
var
  i: Integer;
begin
  Result := False;
  J := nil;
  FQLock.Enter;
  try
    if FViewQ.Count > 0 then
    begin
      J := TPzJob(FViewQ[0]);
      FViewQ.Delete(0);
      Exit(True);
    end;
    { visible thumbnails, newest request first; drop ones scrolled away }
    while FThumbQ.Count > 0 do
    begin
      i := FThumbQ.Count - 1;
      J := TPzJob(FThumbQ[i]);
      FThumbQ.Delete(i);
      if J.Photo.WantEpoch >= Epoch - 1 then
        Exit(True);
      J.Photo.BmpPending := False;
      J.Free;
      J := nil;
    end;
    if (FGenQ.Count > 0) and (FGenActive < FGenLimit) then
    begin
      J := TPzJob(FGenQ[0]);
      FGenQ.Delete(0);
      InterlockedIncrement(FGenActive);
      Exit(True);
    end;
  finally
    FQLock.Leave;
  end;
end;

procedure TPzLibrary.PostResult(R: TPzResult);
var
  NeedQueue: Boolean;
begin
  FQLock.Enter;
  FResults.Add(R);
  NeedQueue := not FDeliverQueued;
  FDeliverQueued := True;
  FQLock.Leave;
  if NeedQueue then
    TThread.Queue(nil, @DeliverResults);
end;

procedure TPzLibrary.DeliverResults;
var
  L: TList;
  i: Integer;
  R: TPzResult;
begin
  FQLock.Enter;
  L := FResults;
  FResults := TList.Create;
  FDeliverQueued := False;
  FQLock.Leave;
  try
    for i := 0 to L.Count - 1 do
    begin
      R := TPzResult(L[i]);
      if FTerminating then
      begin
        R.Free;
        Continue;
      end;
      if R.HaveMeta and (R.Photo <> nil) then
      begin
        if R.Kind <> jkView then
          R.Photo.HasThumb := True;
        if (R.Meta.width > 0) and ((R.Kind <> jkView) or (R.Flags and PZ_THUMB = 0)) then
        begin
          R.Photo.W := R.Meta.width;
          R.Photo.H := R.Meta.height;
        end;
        if R.Meta.taken <> 0 then
          R.Photo.Taken := R.Meta.taken;
        if R.Photo.Camera = '' then
          R.Photo.Camera := PzMake(R.Meta);
        R.Photo.IsRaw := R.Meta.is_raw <> 0;
      end;
      if R.Kind = jkGen then
        Inc(GenDone);
      if R.Kind = jkThumb then
        R.Photo.BmpPending := False;
      if R.Photo <> nil then
        R.Photo.Failed := not R.OK;
      if Assigned(FOnResult) then
        FOnResult(R) // handler may steal R.Img
      ;
      R.Free;
    end;
  finally
    L.Free;
  end;
end;

procedure TPzLibrary.ApplyScanDir(D: TPzScanDir);
var
  F: TPzFolder;
  i, k: Integer;
  P: TPzPhoto;
  St: psqlite3_stmt;
  Old: TStringList;
  Changed: Boolean;
  NewList: TList;
begin
  F := nil;
  for i := 0 to Folders.Count - 1 do
    if TPzFolder(Folders[i]).Path = D.Path then
    begin
      F := TPzFolder(Folders[i]);
      Break;
    end;
  if D.Unchanged and (F <> nil) then
    Exit;
  FDBLock.Enter;
  try
    Exec('BEGIN');
    if F = nil then
    begin
      F := TPzFolder.Create;
      F.Path := D.Path;
      F.Name := ExtractFileName(D.Path);
      F.DirMTime := D.DirMTime;
      F.SortDate := FolderDateFromName(F.Name, D.DirMTime);
      sqlite3_prepare_v2(FDB, 'INSERT OR IGNORE INTO folders(path,mtime) VALUES(?,?)',
        -1, @St, nil);
      sqlite3_bind_text(St, 1, PAnsiChar(F.Path), -1, PZ_TRANSIENT);
      sqlite3_bind_int64(St, 2, D.DirMTime);
      sqlite3_step(St);
      sqlite3_finalize(St);
      sqlite3_prepare_v2(FDB, 'SELECT id FROM folders WHERE path=?', -1, @St, nil);
      sqlite3_bind_text(St, 1, PAnsiChar(F.Path), -1, PZ_TRANSIENT);
      if sqlite3_step(St) = SQLITE_ROW then
        F.Id := sqlite3_column_int64(St, 0);
      sqlite3_finalize(St);
      Folders.Add(F);
    end
    else
    begin
      F.DirMTime := D.DirMTime;
      sqlite3_prepare_v2(FDB, 'UPDATE folders SET mtime=? WHERE id=?', -1, @St, nil);
      sqlite3_bind_int64(St, 1, D.DirMTime);
      sqlite3_bind_int64(St, 2, F.Id);
      sqlite3_step(St);
      sqlite3_finalize(St);
    end;
    { merge: keep photo objects that still exist (they may be on screen) }
    Old := TStringList.Create;
    Old.Sorted := True;
    Old.Duplicates := dupIgnore;
    NewList := TList.Create;
    try
      for i := 0 to F.Count - 1 do
        Old.AddObject(F.Photo(i).Name, F.Photo(i));
      for i := 0 to High(D.Entries) do
      begin
        k := Old.IndexOf(D.Entries[i].Name);
        if k >= 0 then
        begin
          P := TPzPhoto(Old.Objects[k]);
          Old.Delete(k);
          Changed := (P.Size <> D.Entries[i].Size) or (P.MTime <> D.Entries[i].MTime);
          if Changed then
          begin
            P.Size := D.Entries[i].Size;
            P.MTime := D.Entries[i].MTime;
            P.HasThumb := False;
            FreeAndNil(P.Bmp);
            sqlite3_prepare_v2(FDB, 'UPDATE photos SET size=?,mtime=? WHERE id=?',
              -1, @St, nil);
            sqlite3_bind_int64(St, 1, P.Size);
            sqlite3_bind_int64(St, 2, P.MTime);
            sqlite3_bind_int64(St, 3, P.Id);
            sqlite3_step(St);
            sqlite3_finalize(St);
            Exec('DELETE FROM thumbs WHERE id=' + IntToStr(P.Id));
          end;
        end
        else
        begin
          P := TPzPhoto.Create;
          P.Folder := F;
          P.Name := D.Entries[i].Name;
          P.Size := D.Entries[i].Size;
          P.MTime := D.Entries[i].MTime;
          P.Fmt := FormatFromExt(P.Name);
          P.IsRaw := P.Fmt = PZ_FMT_RAW;
          sqlite3_prepare_v2(FDB,
            'INSERT OR REPLACE INTO photos(folder,name,size,mtime,w,h,taken,fmt) VALUES(?,?,?,?,0,0,0,?)',
            -1, @St, nil);
          sqlite3_bind_int64(St, 1, F.Id);
          sqlite3_bind_text(St, 2, PAnsiChar(P.Name), -1, PZ_TRANSIENT);
          sqlite3_bind_int64(St, 3, P.Size);
          sqlite3_bind_int64(St, 4, P.MTime);
          sqlite3_bind_int64(St, 5, P.Fmt);
          sqlite3_step(St);
          sqlite3_finalize(St);
          P.Id := sqlite3_last_insert_rowid(FDB);
        end;
        P.Index := NewList.Count;
        NewList.Add(P);
      end;
      { removed files: keep the objects alive until exit (jobs may hold them) }
      for i := 0 to Old.Count - 1 do
      begin
        P := TPzPhoto(Old.Objects[i]);
        Exec('DELETE FROM photos WHERE id=' + IntToStr(P.Id));
        Exec('DELETE FROM thumbs WHERE id=' + IntToStr(P.Id));
        P.Folder := F;
      end;
      F.Photos.Free;
      F.Photos := NewList;
      NewList := nil;
      if F.IniLoaded then
      begin
        FreeAndNil(F.Ini);
        F.IniLoaded := False;
      end;
    finally
      Old.Free;
      NewList.Free;
    end;
    Exec('COMMIT');
  finally
    FDBLock.Leave;
  end;
end;

procedure TPzLibrary.DeliverScan;
var
  L: TList;
  i: Integer;
  Any: Boolean;
begin
  FQLock.Enter;
  L := FScanResults;
  FScanResults := TList.Create;
  FQLock.Leave;
  Any := False;
  try
    for i := 0 to L.Count - 1 do
    begin
      if not FTerminating then
      begin
        if not TPzScanDir(L[i]).Unchanged then
          Any := True;
        ApplyScanDir(TPzScanDir(L[i]));
      end;
      TPzScanDir(L[i]).Free;
    end;
  finally
    L.Free;
  end;
  if Any then
  begin
    SortFolders;
    if Assigned(FOnScanDir) then
      FOnScanDir(Self);
  end;
  if (FScanner <> nil) and FScanner.Finished and ScanBusy then
  begin
    ScanBusy := False;
    if Assigned(FOnScanDone) then
      FOnScanDone(Self);
  end;
end;

procedure TPzLibrary.RequestThumb(P: TPzPhoto; ASize: Integer);
var
  J: TPzJob;
begin
  if P.BmpPending then
    Exit;
  P.BmpPending := True;
  J := TPzJob.Create;
  J.Kind := jkThumb;
  J.Photo := P;
  J.Path := P.Path;
  J.PhotoId := P.Id;
  J.HasThumb := P.HasThumb;
  J.Size := ASize;
  J.Edits := P.Filters;
  J.Rotate := P.Rotate;
  J.Epoch := Epoch;
  FQLock.Enter;
  FThumbQ.Add(J);
  FQLock.Leave;
  FQEvent.SetEvent;
end;

procedure TPzLibrary.RequestView(P: TPzPhoto; MaxW, MaxH, Flags, Token: Integer;
  Front: Boolean);
var
  J: TPzJob;
begin
  J := TPzJob.Create;
  J.Kind := jkView;
  J.Photo := P;
  J.Path := P.Path;
  J.PhotoId := P.Id;
  J.MaxW := MaxW;
  J.MaxH := MaxH;
  J.Flags := Flags;
  J.Token := Token;
  FQLock.Enter;
  if Front then
    FViewQ.Insert(0, J)
  else
    FViewQ.Add(J);
  FQLock.Leave;
  FQEvent.SetEvent;
end;

procedure TPzLibrary.CancelViews(KeepToken: Integer);
var
  i: Integer;
begin
  FQLock.Enter;
  try
    for i := FViewQ.Count - 1 downto 0 do
      if TPzJob(FViewQ[i]).Token <> KeepToken then
      begin
        TPzJob(FViewQ[i]).Photo.ViewPending := False;
        TPzJob(FViewQ[i]).Free;
        FViewQ.Delete(i);
      end;
  finally
    FQLock.Leave;
  end;
end;

procedure TPzLibrary.QueueBackgroundGen;
var
  i, k: Integer;
  F: TPzFolder;
  P: TPzPhoto;
  J: TPzJob;
  L: TList;
begin
  L := TList.Create;
  try
    for i := 0 to Folders.Count - 1 do
    begin
      F := TPzFolder(Folders[i]);
      for k := 0 to F.Count - 1 do
      begin
        P := F.Photo(k);
        if P.HasThumb or P.Failed then
          Continue;
        J := TPzJob.Create;
        J.Kind := jkGen;
        J.Photo := P;
        J.Path := P.Path;
        J.PhotoId := P.Id;
        L.Add(J);
      end;
    end;
    FQLock.Enter;
    for i := 0 to FGenQ.Count - 1 do
      TPzJob(FGenQ[i]).Free;
    FGenQ.Clear;
    FGenQ.Assign(L);
    GenTotal := L.Count;
    GenDone := 0;
    FQLock.Leave;
    FQEvent.SetEvent;
  finally
    L.Free;
  end;
end;

function TPzLibrary.PendingJobs: Integer;
begin
  FQLock.Enter;
  Result := FViewQ.Count + FThumbQ.Count + FGenQ.Count;
  FQLock.Leave;
end;

procedure TPzLibrary.QueueThumbWrite(const T: TPendingThumb);
begin
  FDBLock.Enter;
  try
    SetLength(FPending, Length(FPending) + 1);
    FPending[High(FPending)] := T;
    if Length(FPending) >= 64 then
      FlushPendingLocked;
  finally
    FDBLock.Leave;
  end;
end;

procedure TPzLibrary.FlushPendingLocked;
var
  i: Integer;
  St, Su: psqlite3_stmt;
begin
  if Length(FPending) = 0 then
    Exit;
  Exec('BEGIN');
  sqlite3_prepare_v2(FDB, 'INSERT OR REPLACE INTO thumbs(id,data) VALUES(?,?)',
    -1, @St, nil);
  sqlite3_prepare_v2(FDB, 'UPDATE photos SET w=?,h=?,taken=?,fmt=?,camera=? WHERE id=?',
    -1, @Su, nil);
  for i := 0 to High(FPending) do
  begin
    sqlite3_reset(St);
    sqlite3_bind_int64(St, 1, FPending[i].Id);
    sqlite3_bind_blob(St, 2, @FPending[i].Data[0], Length(FPending[i].Data),
      PZ_TRANSIENT);
    sqlite3_step(St);
    sqlite3_reset(Su);
    sqlite3_bind_int64(Su, 1, FPending[i].W);
    sqlite3_bind_int64(Su, 2, FPending[i].H);
    sqlite3_bind_int64(Su, 3, FPending[i].Taken);
    sqlite3_bind_int64(Su, 4, FPending[i].Fmt);
    sqlite3_bind_text(Su, 5, PAnsiChar(FPending[i].Camera), -1, PZ_TRANSIENT);
    sqlite3_bind_int64(Su, 6, FPending[i].Id);
    sqlite3_step(Su);
  end;
  sqlite3_finalize(St);
  sqlite3_finalize(Su);
  Exec('COMMIT');
  SetLength(FPending, 0);
end;

procedure TPzLibrary.FlushPending;
begin
  FDBLock.Enter;
  try
    FlushPendingLocked;
  finally
    FDBLock.Leave;
  end;
end;

initialization
  Pointer(PZ_TRANSIENT) := Pointer(-1);

end.
