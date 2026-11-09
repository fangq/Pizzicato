{ Round-trip test for pzini on copies of real .picasa.ini files:
    test_ini file1 [file2 ...]
  1. load + force save without changes -> must be byte-identical
     (modulo blank lines, which Picasa does not write)
  2. every filters= chain must re-serialise to the same text
  3. add a filter, save, reload -> new chain present, other keys untouched
  4. (always, in a temp dir) another program rewrites the file between
     load and save: its changes must survive, and only ours go on top }
program test_ini;

{$mode objfpc}{$H+}
uses
  Classes,
  SysUtils,
  pzini;

  function Slurp(const F: string): string;
  var
    S: TStringList;
  begin
    S := TStringList.Create;
    try
      S.LoadFromFile(F);
      Result := S.Text;
    finally
      S.Free;
    end;
  end;

  procedure Spit(const F, S: string);
  var
    L: TStringList;
  begin
    L := TStringList.Create;
    try
      L.Text := S;
      L.SaveToFile(F + '.new');
    finally
      L.Free;
    end;
    RenameFile(F + '.new', F); // as Picasa: a new file
  end;

  procedure Check(Cond: Boolean; const What: string; var Fails: Integer);
  begin
    if not Cond then
    begin
      WriteLn('FAIL race: ', What);
      Inc(Fails);
    end;
  end;

  { someone else (Picasa) writes the file while it is loaded here }
  procedure RaceTests(var Fails: Integer);
  var
    Dir, F: string;
    A, B: TPzIni;
  begin
    Dir := GetTempDir(False) + 'pzini_race_' + IntToStr(GetProcessID);
    ForceDirectories(Dir);
    F := Dir + '/' + PZ_PICASA_INI;
    Spit(F, '[a.jpg]'#10'star=yes'#10'caption=old'#10'[b.jpg]'#10'filters=crop64=1,1;');
    A := TPzIni.Create(F);
    A.Load;
    { the other program: new caption for a, rotate b, a new photo c }
    Spit(F, '[a.jpg]'#10'star=yes'#10'caption=theirs'#10'[b.jpg]'#10 +
      'filters=crop64=1,1;'#10'rotate=rotate(1)'#10'[c.jpg]'#10'star=yes');
    { ours: keywords on a, unstar a, a's caption written unchanged (no
      change: theirs must stay), b's filters changed (ours wins) }
    A.WriteValue('a.jpg', 'keywords', 'mine');
    A.DeleteKey('a.jpg', 'star');
    A.WriteValue('a.jpg', 'caption', 'old');
    A.WriteValue('b.jpg', 'filters', 'crop64=1,2;');
    Check(A.Save, 'save', Fails);
    B := TPzIni.Create(F);
    B.Load;
    Check(B.ReadValue('a.jpg', 'keywords') = 'mine', 'our new key', Fails);
    Check(not B.HasKey('a.jpg', 'star'), 'our delete', Fails);
    Check(B.ReadValue('a.jpg', 'caption') = 'theirs', 'their change kept', Fails);
    Check(B.ReadValue('b.jpg', 'rotate') = 'rotate(1)', 'their new key kept', Fails);
    Check(B.ReadValue('b.jpg', 'filters') = 'crop64=1,2;', 'our change wins', Fails);
    Check(B.ReadValue('c.jpg', 'star') = 'yes', 'their new section kept', Fails);
    B.Free;
    { saved: the next change starts from the file as written }
    Spit(F, '[a.jpg]'#10'caption=again');
    Check(A.ChangedOnDisk, 'change seen', Fails);
    A.WriteValue('d.jpg', 'star', 'yes');
    A.Save;
    B := TPzIni.Create(F);
    B.Load;
    Check(B.ReadValue('a.jpg', 'caption') = 'again', 'second round theirs', Fails);
    Check(not B.HasKey('a.jpg', 'keywords'), 'saved changes not replayed', Fails);
    Check(B.ReadValue('d.jpg', 'star') = 'yes', 'second round ours', Fails);
    B.Free;
    { Refresh without saving: their change shows, ours stays pending }
    A.WriteValue('a.jpg', 'star', 'yes');
    Spit(F, '[a.jpg]'#10'caption=third');
    Check(A.Refresh, 'refresh', Fails);
    Check((A.ReadValue('a.jpg', 'caption') = 'third') and
      (A.ReadValue('a.jpg', 'star') = 'yes') and A.Dirty, 'refresh merge', Fails);
    A.Free;
    DeleteFile(F);
    RemoveDir(Dir);
  end;

var
  i, j, k, Fails, Chains: Integer;
  Ini, Ini2: TPzIni;
  Sec: TPzIniSection;
  Orig, V, Tmp: string;
  C: TPzChain;
begin
  Fails := 0;
  Chains := 0;
  RaceTests(Fails);
  for i := 1 to ParamCount do
  begin
    Tmp := ParamStr(i);
    Orig := Slurp(Tmp);
    Ini := TPzIni.Create(Tmp);
    Ini.Load;
    Ini.Dirty := True;
    Ini.Save;
    if Slurp(Tmp) <> StringReplace(Orig, LineEnding + LineEnding,
      LineEnding, [rfReplaceAll]) then
    begin
      WriteLn('FAIL roundtrip ', Tmp);
      Inc(Fails);
    end;
    for j := 0 to Ini.Count - 1 do
    begin
      Sec := Ini.Sections[j];
      for k := 0 to Sec.Lines.Count - 1 do
        if (Sec.Lines.Names[k] = 'filters') or (Sec.Lines.Names[k] = 'redo') then
        begin
          V := Sec.Lines.ValueFromIndex[k];
          Inc(Chains);
          if ChainToString(ParseChain(V)) <> V then
          begin
            WriteLn('FAIL chain ', Tmp, ' [', Sec.Name, '] ', V,
              ' -> ', ChainToString(ParseChain(V)));
            Inc(Fails);
          end;
        end;
    end;
    if Ini.Count > 0 then
    begin
      Sec := Ini.Sections[Ini.Count - 1];
      C := ParseChain(Ini.ReadValue(Sec.Name, 'filters'));
      ChainAppend(C, MakeFilter('fill', [FmtF(0.25)]));
      Ini.WriteValue(Sec.Name, 'filters', ChainToString(C));
      Ini.Save;
      Ini2 := TPzIni.Create(Tmp);
      Ini2.Load;
      if Ini2.ReadValue(Sec.Name, 'filters') <> ChainToString(C) then
      begin
        WriteLn('FAIL modify ', Tmp);
        Inc(Fails);
      end;
      if Ini2.Count <> Ini.Count then
      begin
        WriteLn('FAIL section count ', Tmp);
        Inc(Fails);
      end;
      Ini2.Free;
    end;
    Ini.Free;
  end;
  WriteLn(Format('%d files, %d chains, %d failures', [ParamCount, Chains, Fails]));
  if Fails > 0 then Halt(1);
end.
