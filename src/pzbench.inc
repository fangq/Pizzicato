{ Benchmark driver for Pizzicato, included by mainform.pas.
  Run:  pizzicato --bench --log=/path/log.txt [--db=/tmp/x.db] <photo root>
  Never writes .picasa.ini (PzIniReadOnly is forced on). }

procedure TMainForm.BLog(const S: string);
var
  L: string;
begin
  if not (FBench or FGenAll) then
    Exit;
  L := Format('[%8.3f] %s', [NowSeconds - PzStartTime, S]);
  WriteLn(StdErr, L);
  if FBenchLogOpen then
  begin
    WriteLn(FBenchLog, L);
    Flush(FBenchLog);
  end;
end;

function TMainForm.BenchCond(Cond: Integer): Boolean;
var
  T, R: Integer;
begin
  case Cond of
    BC_VISIBLE: Result := Grid.VisibleReady(T, R);
    BC_VIEWFULL: Result := FFirstFullMs >= 0;
    BC_SCANDONE: Result := not Lib.ScanBusy;
    BC_GENDONE: Result := Lib.GenDone >= Lib.GenTotal;
  else
    Result := True;
  end;
end;

procedure TMainForm.BenchWait(Cond: Integer; TimeoutSec: Double; out Elapsed: Double);
var
  T0: Double;
begin
  T0 := NowSeconds;
  repeat
    CheckSynchronize(0);
    Application.ProcessMessages;
    if BenchCond(Cond) then
      Break;
    if Application.Terminated then
      Break;
    Sleep(1);
  until NowSeconds - T0 > TimeoutSec;
  Elapsed := NowSeconds - T0;
end;

procedure BenchIdle(Sec: Double);
var
  T0: Double;
begin
  T0 := NowSeconds;
  while NowSeconds - T0 < Sec do
  begin
    CheckSynchronize(0);
    Application.ProcessMessages;
    Sleep(1);
  end;
end;

function Median(var A: array of Double; N: Integer): Double;
var
  i, j: Integer;
  t: Double;
begin
  if N = 0 then
    Exit(0);
  for i := 1 to N - 1 do
  begin
    t := A[i];
    j := i - 1;
    while (j >= 0) and (A[j] > t) do
    begin
      A[j + 1] := A[j];
      Dec(j);
    end;
    A[j + 1] := t;
  end;
  Result := A[N div 2];
end;

procedure TMainForm.BenchViewer(F: TPzFolder; N: Integer; Dwell: Double);
var
  i, k, Cnt, Instant: Integer;
  E: Double;
  Lat: array of Double;
  Sum, Mx: Double;
  Kind: string;
begin
  for i := 0 to Cache.Count - 1 do
    TViewEntry(Cache[i]).Free;
  Cache.Clear;
  N := Min(N, F.Count);
  SetLength(Lat, N);
  SetEditMode(True);
  BenchIdle(0.2);
  if F.Photo(0).IsRaw then Kind := 'raw' else Kind := 'jpg';
  ShowPhoto(F.Photo(0));
  BenchWait(BC_VIEWFULL, 30, E);
  BLog(Format('  viewer open %s (%s, %dx%d): first full-quality frame %.1f ms',
    [F.Photo(0).Name, Kind, Viewer.ClientWidth, Viewer.ClientHeight, FFirstFullMs]));
  Cnt := 0;
  Sum := 0;
  Mx := 0;
  Instant := 0;
  for k := 1 to N - 1 do
  begin
    if Dwell > 0 then
      BenchIdle(Dwell);
    Navigate(1);
    BenchWait(BC_VIEWFULL, 30, E);
    Lat[Cnt] := FFirstFullMs;
    Sum := Sum + FFirstFullMs;
    Mx := Max(Mx, FFirstFullMs);
    if FFirstFullMs < 50 then
      Inc(Instant);
    Inc(Cnt);
  end;
  if Cnt > 0 then
    BLog(Format('  viewer next x%d (dwell %.0f ms): mean %.1f ms, median %.1f ms, max %.1f ms, <50ms: %d/%d, last render %.1f ms',
      [Cnt, Dwell * 1000, Sum / Cnt, Median(Lat, Cnt), Mx, Instant, Cnt, FLastRenderMs]));
  SetEditMode(False);
end;

procedure TMainForm.BenchEdit(P: TPzPhoto);
const
  Names: array[TSliderKind] of string = ('Basic fill light', 'Straighten', 'Tuning fill', 'Highlights',
    'Shadows', 'Color temperature', 'Brightness', 'Contrast', 'Sharpen', 'Saturation', 'Boost',
    'Soft focus', 'Vignette', 'AI denoise');
var
  OrigF, OrigR: string;
  K: TSliderKind;
  v, n: Integer;
  T0, Tot, E, Mx: Double;
  Btn: string;
  B: TButton;
  ImgW, ImgH: Integer;
  procedure TimeRender(const What: string);
  var
    T: Double;
  begin
    T := NowSeconds;
    RenderCurrent;
    T := (NowSeconds - T) * 1000;
    BLog(Format('    %-28s %7.1f ms   chain=%d filters', [What, T, Length(ParseChain(P.Filters))]));
  end;
begin
  for v := 0 to Cache.Count - 1 do
    TViewEntry(Cache[v]).Free;
  Cache.Clear;
  SetEditMode(True);
  ShowPhoto(P);
  BenchWait(BC_VIEWFULL, 30, E);
  OrigF := P.Filters;
  OrigR := P.Redo;
  if CacheFind(P, 1) <> nil then
  begin
    ImgW := CacheFind(P, 1).Img.w;
    ImgH := CacheFind(P, 1).Img.h;
  end
  else
  begin
    ImgW := 0;
    ImgH := 0;
  end;
  BLog(Format('  edit bench on %s (base %dx%d, existing filters "%s")', [P.Name, ImgW, ImgH, OrigF]));
  P.Filters := '';
  P.Redo := '';
  LoadSlidersFromChain;
  { slider drags: 10 positions each, each re-renders the whole chain }
  for K := Low(TSliderKind) to Pred(skDenoise) do
  begin
    P.Filters := '';
    LoadSlidersFromChain;
    Tot := 0;
    Mx := 0;
    n := 0;
    for v := 1 to 10 do
    begin
      Sliders[K].Position := Sliders[K].Min + (Sliders[K].Max - Sliders[K].Min) * v div 10;
      T0 := NowSeconds;
      RenderCurrent;
      T0 := (NowSeconds - T0) * 1000;
      Tot := Tot + T0;
      Mx := Max(Mx, T0);
      Inc(n);
      CheckSynchronize(0);
      Application.ProcessMessages;
    end;
    BLog(Format('    slider %-21s mean %6.1f ms  max %6.1f ms  (%d steps)', [Names[K], Tot / n, Mx, n]));
  end;
  { one-click fixes and effects }
  for Btn in ['enhance', 'autolight', 'autocolor', 'bw', 'sepia', 'warm'] do
  begin
    P.Filters := '';
    AppendFilter(Btn, []);
    TimeRender('button ' + Btn);
  end;
  P.Filters := '';
  AppendFilter('crop64', [Crop64Encode(0.1, 0.1, 0.8, 0.85)]);
  TimeRender('crop (70%x75%)');
  P.Filters := '';
  { a realistic stacked edit, like the user's own Picasa chains }
  P.Filters := 'autolight=1;finetune2=1,0.300000,0.050000,0.060000,00000000,0.100000;Boost=1,7.6;' +
    'unsharp2=1,0.5;tilt=1,0.2,0;crop64=1,' + Crop64Encode(0.05, 0.05, 0.95, 0.95) + ';';
  TimeRender('stack of 6 filters');
  P.Rotate := 1;
  TimeRender('stack + rotate 90');
  P.Rotate := 0;
  { 100% zoom: full-resolution decode + full chain }
  T0 := NowSeconds;
  Viewer.Zoom100 := True;
  Lib.RequestView(P, 0, 0, RawFlags or PZ_RAW_FULL, -1, True);
  FFirstFullMs := -1;
  repeat
    CheckSynchronize(0);
    Application.ProcessMessages;
    Sleep(1);
  until (CacheFind(P, 3) <> nil) or (NowSeconds - T0 > 60);
  BLog(Format('    100%% decode (full res)       %7.1f ms', [(NowSeconds - T0) * 1000]));
  if CacheFind(P, 3) <> nil then
    BLog(Format('      full-res size %dx%d', [CacheFind(P, 3).Img.w, CacheFind(P, 3).Img.h]));
  TimeRender('stack at 100% (full res)');
  { panning at 1:1: what a drag costs per frame }
  Tot := 0;
  Mx := 0;
  for v := 0 to 19 do
  begin
    Viewer.SetZoomCenter(0.2 + 0.03 * v, 0.3 + 0.02 * v);
    T0 := NowSeconds;
    Application.ProcessMessages; // the expose event: the real paint
    gdk_flush;                   // and wait for the X server to draw it
    T0 := (NowSeconds - T0) * 1000;
    Tot := Tot + T0;
    Mx := Max(Mx, T0);
  end;
  BLog(Format('    pan at 100%% (paint)          mean %6.1f ms  max %6.1f ms  (20 frames)', [Tot / 20, Mx]));
  P.Filters := '';
  TimeRender('no edits at 100% (full res)');
  T0 := NowSeconds;
  ZoomClick(nil);
  Application.ProcessMessages;
  gdk_flush;
  ZoomClick(nil);
  Application.ProcessMessages; // the first 1:1 paint
  gdk_flush;
  BLog(Format('    1:1 -> fit -> 1:1 (cached)    %7.1f ms', [(NowSeconds - T0) * 1000]));
  Viewer.Zoom100 := False;
  P.Filters := OrigF;
  P.Redo := OrigR;
  LoadSlidersFromChain;
  SetEditMode(False);
  B := nil;
  if B = nil then;
end;

function FindFolder(Lib: TPzLibrary; const Sub: string; MinCount: Integer; WantRaw: Integer): TPzFolder;
var
  i: Integer;
  F: TPzFolder;
begin
  Result := nil;
  for i := 0 to Lib.Folders.Count - 1 do
  begin
    F := TPzFolder(Lib.Folders[i]);
    if (F.Count >= MinCount) and ((Sub = '') or (Pos(Sub, F.Name) > 0)) then
    begin
      if (WantRaw = 1) and not F.Photo(0).IsRaw then Continue;
      if (WantRaw = 0) and F.Photo(0).IsRaw then Continue;
      Exit(F);
    end;
  end;
end;

{ AI denoise through the editor: screen size, then 1:1 full resolution, then
  the same again from the disk cache }
procedure TMainForm.BenchAI(P: TPzPhoto);
var
  T0, E: Double;
  i: Integer;
  Why: string;
  Img: Tpz_image;
  M: Tpz_meta;
  W, H: Integer;

  function WaitAI(Lvl: Integer; TimeoutSec: Double): Double;
  var
    En: TViewEntry;
  begin
    T0 := NowSeconds;
    repeat
      CheckSynchronize(0);
      Application.ProcessMessages;
      Sleep(2);
      En := CacheFind(P, Lvl);
      if (En <> nil) and (AIFind(AIKey(P, akDenoise, En.Img.w, En.Img.h)) <> nil) then
        Break;
    until NowSeconds - T0 > TimeoutSec;
    Result := (NowSeconds - T0) * 1000;
  end;

begin
  if not PzAIReady(akDenoise, Why) then
  begin
    BLog('  AI: ' + Why);
    Exit;
  end;
  BLog(Format('  AI denoise on %s (%dx%d):', [P.Name, P.W, P.H]));
  for i := 0 to Cache.Count - 1 do
    TViewEntry(Cache[i]).Free;
  Cache.Clear;
  SetEditMode(True);
  ShowPhoto(P);
  BenchWait(BC_VIEWFULL, 30, E);
  SetDenoise(True, 0.8, False);
  BLog(Format('    screen size, computed          %8.0f ms', [WaitAI(2, 120)]));
  Viewer.Zoom100 := True;
  RequestFull(P, True);
  RenderCurrent;
  BLog(Format('    full resolution, computed      %8.0f ms', [WaitAI(3, 600)]));
  { again, from the disk cache only }
  for i := 0 to FAICache.Count - 1 do
    TPzAIJob(FAICache[i]).Free;
  FAICache.Clear;
  RenderCurrent;
  BLog(Format('    full resolution, disk cache    %8.0f ms', [WaitAI(3, 60)]));
  Viewer.Zoom100 := False;
  { the export path: synchronous, in this thread, at full resolution }
  PzInit(Img);
  if pz_load(PAnsiChar(P.Path), 0, 0, RawFlags or PZ_RAW_FULL, @Img, @M) >= 0 then
  begin
    T0 := NowSeconds;
    PzAIApplyChain(Img, P.Filters, P.Path, nil);
    BLog(Format('    export path (PzAIApplyChain)   %8.0f ms  %s', [(NowSeconds - T0) * 1000,
      IfThen(PzAILastError = '', 'ok', PzAILastError)]));
    pz_free(@Img);
  end;
  { export of a 25% crop at 4x, through the export code itself }
  if PzAIReady(akUpscale, Why) then
  begin
    T0 := NowSeconds;
    ExportImage(P.Path, 'crop64=1,' + Crop64Encode(0.375, 0.375, 0.625, 0.625) + ';',
      0, RawFlags or PZ_RAW_FULL, 4, FAIDir + '/pz_bench_sr.jpg', W, H);
    BLog(Format('    export 25%% crop at 4x          %8.0f ms  -> %dx%d', [(NowSeconds - T0) * 1000, W, H]));
    T0 := NowSeconds;
    ExportImage(P.Path, '', 0, RawFlags or PZ_RAW_FULL, 2, FAIDir + '/pz_bench_sr2.jpg', W, H);
    BLog(Format('    export whole photo at 2x       %8.0f ms  -> %dx%d', [(NowSeconds - T0) * 1000, W, H]));
    DeleteFile(FAIDir + '/pz_bench_sr.jpg');
    DeleteFile(FAIDir + '/pz_bench_sr2.jpg');
  end;
  PzAICloseThread;
  SetDenoise(False, 0, False);
  SetEditMode(False);
end;

{ index every thumbnail for the smart search, then a few queries }
procedure TMainForm.BenchSearch;
const
  Queries: array[0..9] of string = ('fireworks', 'sunset over the ocean', 'rice field',
    'statue', 'birthday cake', 'snow', 'a dog', 'temple', 'people at the beach', 'flowers');
var
  T0, T1, TLast: Double;
  Why: string;
  i, k, n0, m: Integer;
  F: TPzFolder;
  TopS: string;
begin
  if not PzClipReady(Why) then
  begin
    BLog('smart search: ' + Why);
    Exit;
  end;
  BLog('smart search (CLIP ViT-B/32):');
  T0 := NowSeconds;
  StartClipIndex;
  repeat
    CheckSynchronize(0);
    Application.ProcessMessages;
    Sleep(20);
  until ClipIdx.LabelsReady or (ClipIdx.Error <> '') or (NowSeconds - T0 > 120);
  BLog(Format('  %d scene labels embedded in %.0f ms', [PzSceneLabelCount, (NowSeconds - T0) * 1000]));
  n0 := ClipIdx.Indexed;
  T1 := NowSeconds;
  TLast := T1;
  repeat
    CheckSynchronize(0);
    Application.ProcessMessages;
    Sleep(50);
    if NowSeconds - TLast > 60 then
    begin
      TLast := NowSeconds;
      BLog(Format('  indexed %d / %d  (%.1f photos/s)', [ClipIdx.Indexed, ClipIdx.Total,
        (ClipIdx.Indexed - n0) / (NowSeconds - T1)]));
    end;
  until ((ClipIdx.Total > 0) and (ClipIdx.Indexed >= ClipIdx.Total)) or
    (ClipIdx.Error <> '') or (NowSeconds - T1 > 7200);
  BLog(Format('  indexed %d / %d in %.1f s (%.1f photos/s)%s', [ClipIdx.Indexed, ClipIdx.Total,
    NowSeconds - T1, (ClipIdx.Indexed - n0) / Max(0.001, NowSeconds - T1),
    IfThen(ClipIdx.Error <> '', ' error: ' + ClipIdx.Error, '')]));
  ChkSmart.Down := True;
  for i := 0 to High(Queries) do
  begin
    EdSearch.Text := Queries[i];
    T0 := NowSeconds;
    SmartSearch;
    T0 := (NowSeconds - T0) * 1000;
    TopS := '';
    m := 0;
    for k := 0 to Lib.Folders.Count - 1 do
    begin
      F := TPzFolder(Lib.Folders[k]);
      for n0 := 0 to F.Count - 1 do
        if F.Photo(n0).SmartHit and (m < 4) then
        begin
          TopS := TopS + ' ' + F.Name + '/' + F.Photo(n0).Name;
          Inc(m);
        end;
    end;
    BLog(Format('    %.0f ms; first hits in grid order:%s', [T0, TopS]));
  end;
  EdSearch.Text := '';
  SmartSearch;
end;

procedure TMainForm.RunBench;
var
  E, T0, Pos0: Double;
  i, n, Tot, Rdy, Had: Integer;
  F: TPzFolder;
  Lat: array[0..63] of Double;
  Sum, Mx: Double;
  P: TPzPhoto;
  Img: Tpz_image;
  M: Tpz_meta;
  OutDir: string;
  k: Integer;
begin
  if GetEnvironmentVariable('PZ_BENCH_ONLY') = 'search' then
  begin
    BenchSearch; // PZ_BENCH_ONLY=search: just index and query
    BLog('bench done');
    Exit;
  end;
  BLog(Format('window shown; roots=%s; workers=%d; grid %dx%d thumb %d',
    [Lib.Roots.CommaText, PzCPUCount, Grid.ClientWidth, Grid.ClientHeight, Grid.ThumbSize]));
  n := 0;
  for i := 0 to Lib.Folders.Count - 1 do
    Inc(n, TPzFolder(Lib.Folders[i]).Count);
  BLog(Format('from DB: %d folders, %d photos', [Lib.Folders.Count, n]));
  { 1. first screen of thumbnails straight from the DB }
  Grid.Relayout;
  Grid.Repaint;
  BenchWait(BC_VISIBLE, 600, E);
  Grid.VisibleReady(Tot, Rdy);
  BLog(Format('first screen: %d/%d thumbnails ready %.1f ms after window shown (%.1f ms since process start)',
    [Rdy, Tot, E * 1000, (NowSeconds - PzStartTime) * 1000]));
  { 2. folder scan (full walk on first run, change detection afterwards) }
  T0 := NowSeconds;
  Lib.StartScan;
  BenchWait(BC_SCANDONE, 3600, E);
  RebuildTree;
  Grid.Relayout;
  n := 0;
  for i := 0 to Lib.Folders.Count - 1 do
    Inc(n, TPzFolder(Lib.Folders[i]).Count);
  BLog(Format('folder scan: %.1f ms, %d folders, %d photos', [E * 1000, Lib.Folders.Count, n]));
  Grid.Repaint;
  BenchWait(BC_VISIBLE, 600, E);
  Grid.VisibleReady(Tot, Rdy);
  BLog(Format('first screen after scan: %d/%d ready in %.1f ms', [Rdy, Tot, E * 1000]));
  { 3. jump-scrolling through the whole library }
  for k := 0 to 1 do
  begin
    n := 0;
    Sum := 0;
    Mx := 0;
    for i := 1 to 16 do
    begin
      Pos0 := Grid.TotalHeight * i / 17;
      Grid.SetScrollY(Round(Pos0));
      Grid.Repaint;
      BenchWait(BC_VISIBLE, 300, E);
      Grid.VisibleReady(Tot, Rdy);
      Lat[n] := E * 1000;
      Sum := Sum + E * 1000;
      Mx := Max(Mx, E * 1000);
      Inc(n);
    end;
    if k = 0 then
      BLog(Format('jump-scroll x%d (thumbs from DB or generated): mean %.1f ms, median %.1f ms, max %.1f ms',
        [n, Sum / n, Median(Lat, n), Mx]))
    else
      BLog(Format('jump-scroll x%d revisit (bitmaps in memory):    mean %.1f ms, median %.1f ms, max %.1f ms',
        [n, Sum / n, Median(Lat, n), Mx]));
  end;
  { 4. smooth scroll: wheel-sized steps, how often the screen is complete }
  Grid.SetScrollY(0);
  BenchWait(BC_VISIBLE, 300, E);
  n := 0;
  Had := 0;
  T0 := NowSeconds;
  Sum := 0;
  Mx := 0;
  for i := 1 to 240 do
  begin
    { 60 Hz wheel scrolling: one step per 16.7 ms frame }
    Pos0 := NowSeconds;
    Grid.SetScrollY(Grid.ScrollY + Grid.ThumbSize div 3);
    Grid.Repaint;
    Pos0 := (NowSeconds - Pos0) * 1000;
    Sum := Sum + Pos0;
    Mx := Max(Mx, Pos0);
    if Grid.VisibleReady(Tot, Rdy) then
      Inc(Had);
    Inc(n);
    BenchIdle(1 / 60);
  end;
  E := NowSeconds - T0;
  BLog(Format('smooth scroll at 60 Hz, %d frames of %d px (%.0f px/s): paint mean %.2f ms max %.2f ms, ' +
    'screen fully populated on %d/%d frames', [n, Grid.ThumbSize div 3, n * (Grid.ThumbSize div 3) / E,
    Sum / n, Mx, Had, n]));
  { 5. thumbnail size change re-decodes from the cache }
  Grid.SetScrollY(0);
  BenchWait(BC_VISIBLE, 300, E);
  TrkSize.Position := 256;
  Grid.Repaint;
  BenchWait(BC_VISIBLE, 300, E);
  Grid.VisibleReady(Tot, Rdy);
  BLog(Format('thumb size 160->256: %d thumbs ready in %.1f ms', [Tot, E * 1000]));
  TrkSize.Position := 160;
  BenchWait(BC_VISIBLE, 300, E);
  { 6. viewer }
  F := FindFolder(Lib, 'K5', 25, 1);
  if F <> nil then
  begin
    BLog('viewer, Pentax K-5 DNG folder ' + F.Name + ':');
    BenchViewer(F, 25, 0);
    BenchViewer(F, 25, 0.4);
  end;
  F := FindFolder(Lib, 'Pixel2Raw', 10, 1);
  if F <> nil then
  begin
    BLog('viewer, Pixel 2 DNG folder ' + F.Name + ' (small embedded preview → LibRaw half-size decode):');
    BenchViewer(F, 20, 0);
    BenchViewer(F, 20, 0.4);
  end;
  F := FindFolder(Lib, 'Pixel7', 25, 0);
  if F = nil then
    F := FindFolder(Lib, '', 25, 0);
  if F <> nil then
  begin
    BLog('viewer, JPEG folder ' + F.Name + ':');
    BenchViewer(F, 25, 0);
    BenchViewer(F, 25, 0.4);
  end;
  { raw rendering through LibRaw instead of the camera preview }
  F := FindFolder(Lib, 'K5', 25, 1);
  if F <> nil then
  begin
    ChkRawPreview.Checked := False;
    BLog('viewer, K-5 DNG with LibRaw rendering (camera preview disabled):');
    BenchViewer(F, 12, 0);
    BenchViewer(F, 12, 0.4);
    ChkRawPreview.Checked := True;
  end;
  { 7. editing }
  BLog('editing:');
  F := FindFolder(Lib, 'K5', 25, 1);
  if F = nil then
    F := FindFolder(Lib, '', 4, 1); // a small test library
  if F <> nil then
  begin
    BenchEdit(F.Photo(3));
    BenchAI(F.Photo(3));
  end;
  F := FindFolder(Lib, 'Pixel7', 25, 0);
  if F = nil then
    F := FindFolder(Lib, '', 25, 0);
  if F = nil then
    F := FindFolder(Lib, '', 4, 0);
  if F <> nil then
    BenchEdit(F.Photo(3));
  BenchSearch;
  { 8. full-resolution export (decode + chain + JPEG q92) }
  OutDir := GetEnvironmentVariable('PZ_BENCH_OUT');
  if OutDir <> '' then
  begin
    BLog('export (full resolution, stacked edit):');
    for k := 0 to 1 do
    begin
      if k = 0 then F := FindFolder(Lib, 'K5', 25, 1) else F := FindFolder(Lib, 'Pixel7', 25, 0);
      if F = nil then
        Continue;
      P := F.Photo(3);
      T0 := NowSeconds;
      if pz_load(PAnsiChar(P.Path), 0, 0, RawFlags or PZ_RAW_FULL, @Img, @M) >= 0 then
      begin
        E := NowSeconds;
        RenderChain(Img, ParseChain('autolight=1;finetune2=1,0.3,0.05,0.06,00000000,0.1;unsharp2=1,0.5;'), 0);
        Pos0 := NowSeconds;
        pz_save_jpeg(PAnsiChar(OutDir + '/' + ChangeFileExt(P.Name, '.jpg')), @Img, 92);
        BLog(Format('  %s %dx%d: decode %.0f ms, filters %.0f ms, encode %.0f ms, total %.0f ms',
          [P.Name, Img.w, Img.h, (E - T0) * 1000, (Pos0 - E) * 1000, (NowSeconds - Pos0) * 1000,
          (NowSeconds - T0) * 1000]));
        pz_free(@Img);
      end;
    end;
  end;
  BLog('bench done');
  Close;
end;

procedure TMainForm.RunGenAll;
var
  T0, LastT, E: Double;
  LastDone, n, i: Integer;
begin
  BLog('gen-all: scanning');
  T0 := NowSeconds;
  Lib.StartScan;
  BenchWait(BC_SCANDONE, 7200, E);
  n := 0;
  for i := 0 to Lib.Folders.Count - 1 do
    Inc(n, TPzFolder(Lib.Folders[i]).Count);
  BLog(Format('gen-all: scan %.1f s, %d folders, %d photos', [E, Lib.Folders.Count, n]));
  RebuildTree;
  Grid.Relayout;
  Lib.QueueBackgroundGen;
  BLog(Format('gen-all: %d thumbnails to build', [Lib.GenTotal]));
  T0 := NowSeconds;
  LastT := T0;
  LastDone := 0;
  while (Lib.GenDone < Lib.GenTotal) and not Application.Terminated do
  begin
    BenchIdle(0.5);
    if NowSeconds - LastT >= 30 then
    begin
      BLog(Format('gen-all: %d / %d  (%.1f/s last 30 s, %.1f/s overall)', [Lib.GenDone, Lib.GenTotal,
        (Lib.GenDone - LastDone) / (NowSeconds - LastT), Lib.GenDone / (NowSeconds - T0)]));
      LastT := NowSeconds;
      LastDone := Lib.GenDone;
    end;
  end;
  Lib.FlushPending;
  BLog(Format('gen-all: done %d thumbnails in %.1f s (%.1f/s)', [Lib.GenDone, NowSeconds - T0,
    Lib.GenDone / Max(0.001, NowSeconds - T0)]));
  Close;
end;

procedure TMainForm.RunBenchAsync(Data: PtrInt);
begin
  RunBench;
end;

procedure TMainForm.RunGenAllAsync(Data: PtrInt);
begin
  RunGenAll;
end;
