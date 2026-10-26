program PiFalseStartSearchConsole;

{$APPTYPE CONSOLE}

uses
  Winapi.Windows, System.Classes, System.SysUtils,
  PFSUnit.FalseStartSearch in 'Source\Units\PFSUnit.FalseStartSearch.pas',
  PFSUnit.Report in 'Source\Units\PFSUnit.Report.pas',
  PFSUnit.RunLog in 'Source\Units\PFSUnit.RunLog.pas';

type
  TPFSConsoleRunner = class(TObject)
  strict private
    FEnded: Boolean;
    FListedKinds: TPFSMatchKinds;
    FPiSearcher: TPiFalseStartSearcher;
    FRunLog: TPFSConsoleRunLog;
    procedure ApplySwitch(const AParam: string; var AFileNames: TArray<string>; var AContinuationFiles: Boolean);
    procedure FalseStartFound(const APiSearcher: TPiFalseStartSearcher; const AMatch: TPFSMatch);
    procedure SearchEnded(const APiSearcher: TPiFalseStartSearcher);
    procedure WriteUsage;
  public
    destructor Destroy; override;

    function Run: Integer;
  end;

var
  GPiSearcher: TPiFalseStartSearcher = nil;

function ParseReadMethod(const AValue: string): TPFSReadMethod;
begin
  for var LReadMethod := Low(TPFSReadMethod) to High(TPFSReadMethod) do
    if SameText(AValue, READ_METHOD_SWITCHES[LReadMethod]) then
      Exit(LReadMethod);

  raise EArgumentException.CreateFmt('Unknown read method "%s"', [AValue]);
end;

function ConsoleCtrlHandler(ACtrlType: DWORD): BOOL; stdcall;
begin
  Result := (ACtrlType = CTRL_C_EVENT) or (ACtrlType = CTRL_BREAK_EVENT);

  if Result and Assigned(GPiSearcher) then
    GPiSearcher.Cancel;
end;

{ TPFSConsoleRunner }

destructor TPFSConsoleRunner.Destroy;
begin
  GPiSearcher := nil;
  // Before the log its events write to
  FPiSearcher.Free;
  FRunLog.Free;

  inherited Destroy;
end;

procedure TPFSConsoleRunner.ApplySwitch(const AParam: string; var AFileNames: TArray<string>; var AContinuationFiles: Boolean);
var
  LName: string;
  LSeparator: Integer;
  LValue: string;
begin
  if not (AParam.StartsWith('-') or AParam.StartsWith('/')) then
  begin
    AFileNames := AFileNames + [AParam];
    Exit;
  end;

  LName := AParam.Substring(1);
  LValue := '';
  LSeparator := LName.IndexOf(':');

  if LSeparator >= 0 then
  begin
    LValue := LName.Substring(LSeparator + 1);
    LName := LName.Substring(0, LSeparator);
  end;

  if SameText(LName, 'BufferMB') then
    FPiSearcher.BufferSize := LValue.ToInteger * 1024 * 1024
  else if SameText(LName, 'List') then
    FPiSearcher.ListMatchLength := LValue.ToInteger
  else if SameText(LName, 'LogAll') then
    FPiSearcher.OnlyNewLongestMatches := False
  else if SameText(LName, 'Min') then
    FPiSearcher.MinMatchLength := LValue.ToInteger
  else if SameText(LName, 'NoContinuation') then
    AContinuationFiles := False
  else if SameText(LName, 'Out') then
    FRunLog.SummaryFileName := LValue
  else if SameText(LName, 'Read') then
    FPiSearcher.ReadMethod := ParseReadMethod(LValue)
  else if SameText(LName, 'SelfLocating') then
    FPiSearcher.SearchSelfLocating := True
  else if SameText(LName, 'SummaryFalseStarts') then
    Include(FListedKinds, mkFalseStart)
  else if SameText(LName, 'SummaryNewLongest') then
    Include(FListedKinds, mkNewLongest)
  else
    raise EArgumentException.CreateFmt('Unknown switch "%s"', [AParam]);
end;

procedure TPFSConsoleRunner.FalseStartFound(const APiSearcher: TPiFalseStartSearcher; const AMatch: TPFSMatch);
begin
  FRunLog.LogMatch(APiSearcher, AMatch);
end;

function TPFSConsoleRunner.Run: Integer;
var
  LContinuationFiles: Boolean;
  LFileNames: TArray<string>;
begin
  FRunLog := TPFSConsoleRunLog.Create;
  FPiSearcher := TPiFalseStartSearcher.Create(FalseStartFound, SearchEnded);

  LContinuationFiles := True;
  LFileNames := [];

  for var LIndex := 1 to ParamCount do
    ApplySwitch(ParamStr(LIndex), LFileNames, LContinuationFiles);

  if Length(LFileNames) = 0 then
  begin
    WriteUsage;
    Exit(1);
  end;

  // With several files given, they are searched as given
  if LContinuationFiles and (Length(LFileNames) = 1) then
    LFileNames := TPiFalseStartSearcher.FindContinuationFiles(LFileNames[0]);

  FPiSearcher.Execute(LFileNames);
  GPiSearcher := FPiSearcher;
  SetConsoleCtrlHandler(@ConsoleCtrlHandler, True);

  FRunLog.LogRunStarted(FPiSearcher);

  // Runs the queued match and end events of the search thread
  while not FEnded do
  begin
    CheckSynchronize(1000);

    if not FEnded then
      FRunLog.ShowProgress(FPiSearcher.Progress);
  end;

  case FPiSearcher.Status of
    rsFinished: Result := 0;
    rsCanceled: Result := 2;
  else
    Result := 3;
  end;
end;

procedure TPFSConsoleRunner.SearchEnded(const APiSearcher: TPiFalseStartSearcher);
begin
  FEnded := True;
  FRunLog.LogRunEnded(APiSearcher, FListedKinds);
end;

procedure TPFSConsoleRunner.WriteUsage;
begin
  WriteLn('Usage: PiFalseStartSearchConsole <first digit file> [more files] [switches]');
  WriteLn;
  WriteLn('  -BufferMB:N      Read buffer size in MB (default 64)');
  WriteLn('  -List:N          Length for -SummaryFalseStarts and -LogAll (default 10)');
  WriteLn('  -LogAll          While running, log every false start of the -List length, not only a new longest one');
  WriteLn('  -Min:N           Count false starts from N digits up (default and minimum 4)');
  WriteLn('  -NoContinuation  Do not continue with the numbered follow-up files (_02, _03, ...)');
  WriteLn('  -Out:FileName    Also save the summary to a file');
  WriteLn('  -Read:Method     How the files are read (default ReadFile):');

  for var LReadMethod := Low(TPFSReadMethod) to High(TPFSReadMethod) do
    WriteLn(Format('                     %-10s  %s', [READ_METHOD_SWITCHES[LReadMethod], READ_METHOD_NAMES[LReadMethod]]));

  WriteLn('  -SelfLocating    Also search self-locating strings (digits at position P spell P)');
  WriteLn('  -SummaryFalseStarts  List the false starts of the -List length in the summary, the first 1 000');
  WriteLn('  -SummaryNewLongest   List the new longest false starts in the summary');
  WriteLn;
  WriteLn('Ctrl+C stops the search and prints the results so far.');
  WriteLn('Exit code: 0 finished, 1 usage, 2 canceled, 3 error.');
end;

begin
  try
    var LRunner := TPFSConsoleRunner.Create;
    try
      ExitCode := LRunner.Run;
    finally
      LRunner.Free;
    end;
  except
    on E: Exception do
    begin
      WriteLn(ErrOutput, E.ClassName, ': ', E.Message);
      ExitCode := 3;
    end;
  end;
end.
