unit PFSUnit.Report;

interface

uses
  System.Classes, System.SysUtils, PFSUnit.FalseStartSearch;

type
  TPFSMatchKinds = set of TPFSMatchKind;

function FormatElapsed(const ASeconds: Double): string;
function FormatMatch(const APiSearcher: TPiFalseStartSearcher; const AMatch: TPFSMatch): string;
function FormatProgress(const AProgress: TPFSProgress): string;
function IntToStrTS(const AValue: UInt64; const ASeparator: Char = ' '): string;
// AListedKinds = the match lists added to the summary, the statistics table is always there. Self-locating strings are
// listed whenever they were searched.
procedure AddSummary(const APiSearcher: TPiFalseStartSearcher; const ALines: TStrings; const AListedKinds: TPFSMatchKinds);

implementation

uses
  System.Math;

const
  BYTES_IN_GB = 1000 * 1000 * 1000;

function FormatElapsed(const ASeconds: Double): string;
var
  LSeconds: Int64;
begin
  LSeconds := Trunc(ASeconds);

  Result := Format('%.2d:%.2d:%.2d', [LSeconds div 3600, LSeconds mod 3600 div 60, LSeconds mod 60]);
end;

function FormatExpected(const AExpected: Double): string;
begin
  if AExpected >= 10 then
    Result := IntToStrTS(Round(AExpected))
  else
    Result := FormatFloat('0.###', AExpected);
end;

function FormatMatch(const APiSearcher: TPiFalseStartSearcher; const AMatch: TPFSMatch): string;
begin
  case AMatch.Kind of
    mkFalseStart:
      Result := Format('False start of %d digits at position %s: %s',
        [AMatch.Length, IntToStrTS(AMatch.Position), Copy(APiSearcher.PatternText, 1, AMatch.Length)]);
    // Right-aligned, so the lines line up under a "New longest false starts:" heading
    mkNewLongest:
      Result := Format('%5d digits at position %s: %s',
        [AMatch.Length, IntToStrTS(AMatch.Position), Copy(APiSearcher.PatternText, 1, AMatch.Length)]);
    mkSelfLocating:
      Result := Format('Self-locating string at position %s', [IntToStrTS(AMatch.Position)]);
  else
    Result := '';
  end;
end;

function FormatProgress(const AProgress: TPFSProgress): string;
var
  LBytesPerSecond: Double;
  LPercent: Double;
  LTimeLeft: string;
begin
  LPercent := 0.00;
  LBytesPerSecond := 0.00;
  LTimeLeft := '-';

  if AProgress.BytesTotal > 0 then
    LPercent := 100 * AProgress.BytesRead / AProgress.BytesTotal;

  if AProgress.ElapsedSeconds > 0 then
    LBytesPerSecond := AProgress.BytesRead / AProgress.ElapsedSeconds;

  if LBytesPerSecond > 0 then
    LTimeLeft := FormatElapsed((AProgress.BytesTotal - AProgress.BytesRead) / LBytesPerSecond);

  Result := Format('%s %% - %s / %s GB - %s GB/s - elapsed %s - left %s - longest %d', [
    FormatFloat('0.0', LPercent),
    FormatFloat('0.0', AProgress.BytesRead / BYTES_IN_GB),
    FormatFloat('0.0', AProgress.BytesTotal / BYTES_IN_GB),
    FormatFloat('0.00', LBytesPerSecond / BYTES_IN_GB),
    FormatElapsed(AProgress.ElapsedSeconds),
    LTimeLeft,
    AProgress.LongestMatch]);
end;

function IntToStrTS(const AValue: UInt64; const ASeparator: Char = ' '): string;
var
  LThirdOfLength, LRemainder, LIndex: Integer;
  LPosition, LStep: Integer;
  LLength: Integer;
begin
  Result := UIntToStr(AValue);

  if AValue < 1000 then
    Exit;

  LLength := Length(Result);
  LThirdOfLength := LLength div 3;
  LRemainder := LLength mod 3;

  LStep := LRemainder + 1;

  LPosition := 4;
  if LRemainder <> 0 then
  begin
    Insert(ASeparator, Result, LStep);
    Inc(LPosition, LStep);
  end;

  for LIndex := 1 to (LThirdOfLength - 1) do
  begin
    Insert(ASeparator, Result, LPosition);
    Inc(LPosition, 4);
  end;
end;

function GetFalseStartListTitle(const APiSearcher: TPiFalseStartSearcher; const AStatistics: TPFSLengthStatistics): string;
var
  LFound: Int64;
begin
  LFound := 0;

  for var LLength := Max(APiSearcher.ListMatchLength, APiSearcher.MinMatchLength) to MAX_PATTERN_LENGTH do
    Inc(LFound, AStatistics[LLength].Count);

  Result := Format('False starts of %d digits or more', [APiSearcher.ListMatchLength]);

  if LFound > MAX_LISTED_FALSE_STARTS then
    Result := Result + Format(', %s found, the first %s listed:', [IntToStrTS(LFound), IntToStrTS(MAX_LISTED_FALSE_STARTS)])
  else
    Result := Result + ':';
end;

procedure AddMatchList(const APiSearcher: TPiFalseStartSearcher; const ALines: TStrings; const AKind: TPFSMatchKind;
  const ATitle: string);
begin
  ALines.Add('');
  ALines.Add(ATitle);

  var LFound := False;

  for var LMatch in APiSearcher.GetMatches do
    if LMatch.Kind = AKind then
    begin
      // A new longest is indented by its own format, same as in the log
      if AKind = mkNewLongest then
        ALines.Add(FormatMatch(APiSearcher, LMatch))
      else
        ALines.Add('  ' + FormatMatch(APiSearcher, LMatch));

      LFound := True;
    end;

  if not LFound then
    ALines.Add('  none');
end;

procedure AddStatisticsTable(const APiSearcher: TPiFalseStartSearcher; const ALines: TStrings);
const
  ROW_FORMAT = '%6s %18s %18s %18s %18s';
var
  LAtLeast: Int64;
  LDigitsScanned: Int64;
  LLastLength: Integer;
  LStatistics: TPFSLengthStatistics;
begin
  LStatistics := APiSearcher.GetStatistics;
  LDigitsScanned := APiSearcher.Progress.DigitsScanned;
  // One row past the longest match, to show how unlikely the next length would have been
  LLastLength := Min(Max(APiSearcher.Progress.LongestMatch, APiSearcher.MinMatchLength) + 1, Length(APiSearcher.PatternText));

  ALines.Add('');
  ALines.Add(Format(ROW_FORMAT, ['Length', 'Exactly', 'At least', 'Expected at least', 'First position']));

  for var LLength := APiSearcher.MinMatchLength to LLastLength do
  begin
    LAtLeast := 0;

    for var LLongerLength := LLength to MAX_PATTERN_LENGTH do
      Inc(LAtLeast, LStatistics[LLongerLength].Count);

    var LFirstPosition: string := '-';

    if LStatistics[LLength].Count > 0 then
      LFirstPosition := IntToStrTS(LStatistics[LLength].FirstPosition);

    ALines.Add(Format(ROW_FORMAT, [
      IntToStr(LLength),
      IntToStrTS(LStatistics[LLength].Count),
      IntToStrTS(LAtLeast),
      FormatExpected(LDigitsScanned * Power(10, -LLength)),
      LFirstPosition]));
  end;
end;

procedure AddSummary(const APiSearcher: TPiFalseStartSearcher; const ALines: TStrings; const AListedKinds: TPFSMatchKinds);
var
  LLongestMatch: Integer;
  LProgress: TPFSProgress;
  LStatistics: TPFSLengthStatistics;
begin
  LProgress := APiSearcher.Progress;
  LLongestMatch := LProgress.LongestMatch;
  LStatistics := APiSearcher.GetStatistics;

  ALines.BeginUpdate;
  try
    ALines.Add(Format('Files: %d, %s GB', [Length(APiSearcher.FileNames), FormatFloat('0.00', LProgress.BytesTotal / BYTES_IN_GB)]));
    ALines.Add('Searched prefix: ' + APiSearcher.PatternText);
    ALines.Add('Digits scanned: ' + IntToStrTS(LProgress.DigitsScanned));
    ALines.Add('Non-digit characters skipped: ' + IntToStrTS(APiSearcher.NonDigitCount));

    if APiSearcher.UnexpectedCharCount > 0 then
      ALines.Add(Format('WARNING: %s unexpected characters, first one %s',
        [IntToStrTS(APiSearcher.UnexpectedCharCount), APiSearcher.FirstUnexpectedChar]));

    ALines.Add('Elapsed: ' + FormatElapsed(LProgress.ElapsedSeconds));

    AddStatisticsTable(APiSearcher, ALines);

    ALines.Add('');
    ALines.Add('Positions are 1-based decimal positions, the first digit after the decimal point is at position 1.');
    ALines.Add('Expected at least = digits scanned * 10^-length, if the digits are random.');

    if LLongestMatch > 0 then
    begin
      ALines.Add('');
      ALines.Add(Format('Longest false start: %d digits, first at position %s: %s', [LLongestMatch,
        IntToStrTS(LStatistics[LLongestMatch].FirstPosition), Copy(APiSearcher.PatternText, 1, LLongestMatch)]));
    end;

    if mkNewLongest in AListedKinds then
      AddMatchList(APiSearcher, ALines, mkNewLongest, 'New longest false starts, in the order found:');

    if mkFalseStart in AListedKinds then
      AddMatchList(APiSearcher, ALines, mkFalseStart, GetFalseStartListTitle(APiSearcher, LStatistics));

    if APiSearcher.SearchSelfLocating then
      AddMatchList(APiSearcher, ALines, mkSelfLocating, 'Self-locating strings:');
  finally
    ALines.EndUpdate;
  end;
end;

end.
