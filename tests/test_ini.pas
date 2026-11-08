{ Round-trip test for pzini on copies of real .picasa.ini files:
    test_ini file1 [file2 ...]
  1. load + force save without changes -> must be byte-identical
     (modulo blank lines, which Picasa does not write)
  2. every filters= chain must re-serialise to the same text
  3. add a filter, save, reload -> new chain present, other keys untouched }
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

var
  i, j, k, Fails, Chains: Integer;
  Ini, Ini2: TPzIni;
  Sec: TPzIniSection;
  Orig, V, Tmp: string;
  C: TPzChain;
begin
  Fails := 0;
  Chains := 0;
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
