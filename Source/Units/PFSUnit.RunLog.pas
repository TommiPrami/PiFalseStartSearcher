unit PFSUnit.RunLog;

(*
  What a run writes out: the start lines, the matches as they are found, the
  progress and the summary at the end. TPFSRunLog decides what is written,
  the descendants only where: TPFSConsoleRunLog writes to the console here,
  TPFSMemoRunLog (PFSUnit.RunLog.Memo) to a memo and a label.
*)

interface

uses
  System.Classes, System.SysUtils, PFSUnit.FalseStartSearch, PFSUnit.Report;

type
  TPFSRunLog = class(TObject)
  strict private
    FSummaryFileName: string;
    function GetRunEndedText(const APiSearcher: TPiFalseStartSearcher): string;
  strict protected
    procedure WriteLine(const ALine: string); virtual; abstract;
    // Default writes line by line, override when the output has a faster way
    procedure WriteLines(const ALines: TStrings); virtual;
  public
    procedure Clear; virtual;
    procedure LogFileCachePurged(const AFileNames: TArray<string>);
    procedure LogMatch(const APiSearcher: TPiFalseStartSearcher; const AMatch: TPFSMatch);
    // AListedKinds = the match lists added to the summary, see AddSummary
    procedure LogRunEnded(const APiSearcher: TPiFalseStartSearcher; const AListedKinds: TPFSMatchKinds);
    procedure LogRunStarted(const APiSearcher: TPiFalseStartSearcher);
    procedure ShowProgress(const AProgress: TPFSProgress); virtual; abstract;
    // When set, the summary is also saved to this file at the end of the run
    property SummaryFileName: string read FSummaryFileName write FSummaryFileName;
  end;

  // Lines to standard output, progress on one line of standard error, so a redirected output stays clean
  TPFSConsoleRunLog = class(TPFSRunLog)
  strict private
    FProgressShown: Boolean;
    procedure ClearProgressLine;
  strict protected
    procedure WriteLine(const ALine: string); override;
  public
    procedure ShowProgress(const AProgress: TPFSProgress); override;
  end;

implementation

const
  PROGRESS_LINE_WIDTH = 119;

{ TPFSRunLog }

function TPFSRunLog.GetRunEndedText(const APiSearcher: TPiFalseStartSearcher): string;
begin
  case APiSearcher.Status of
    rsCanceled: Result := 'Run canceled, results so far:';
    rsError: Result := 'Error occurred: ' + APiSearcher.ErrorMessage;
  else
    Result := 'Run finished.';
  end;
end;

procedure TPFSRunLog.Clear;
begin
  // Nothing to clear by default
end;

procedure TPFSRunLog.LogFileCachePurged(const AFileNames: TArray<string>);
begin
  for var LFileName in AFileNames do
    WriteLine('Removed from the file cache: ' + LFileName);
end;

procedure TPFSRunLog.LogMatch(const APiSearcher: TPiFalseStartSearcher; const AMatch: TPFSMatch);
begin
  WriteLine(FormatMatch(APiSearcher, AMatch));
end;

procedure TPFSRunLog.LogRunEnded(const APiSearcher: TPiFalseStartSearcher; const AListedKinds: TPFSMatchKinds);
begin
  ShowProgress(APiSearcher.Progress);

  var LSummary := TStringList.Create;
  try
    LSummary.Add('');
    LSummary.Add(GetRunEndedText(APiSearcher));
    AddSummary(APiSearcher, LSummary, AListedKinds);

    WriteLines(LSummary);

    if not FSummaryFileName.IsEmpty then
      LSummary.SaveToFile(FSummaryFileName, TEncoding.UTF8);
  finally
    LSummary.Free;
  end;
end;

procedure TPFSRunLog.LogRunStarted(const APiSearcher: TPiFalseStartSearcher);
begin
  for var LFileName in APiSearcher.FileNames do
    WriteLine('File: ' + LFileName);

  WriteLine('Searched prefix: ' + APiSearcher.PatternText);
  WriteLine('Reading: ' + READ_METHOD_NAMES[APiSearcher.ReadMethod]);
  WriteLine('');

  // The new longest lines are only "    4 digits at position ...", they need a heading
  if APiSearcher.OnlyNewLongestMatches then
    WriteLine('New longest false starts:');
end;

procedure TPFSRunLog.WriteLines(const ALines: TStrings);
begin
  for var LLine in ALines do
    WriteLine(LLine);
end;

{ TPFSConsoleRunLog }

procedure TPFSConsoleRunLog.ClearProgressLine;
begin
  Write(ErrOutput, #13, StringOfChar(' ', PROGRESS_LINE_WIDTH), #13);
  FProgressShown := False;
end;

procedure TPFSConsoleRunLog.ShowProgress(const AProgress: TPFSProgress);
begin
  Write(ErrOutput, #13, FormatProgress(AProgress), '   ');
  FProgressShown := True;
end;

procedure TPFSConsoleRunLog.WriteLine(const ALine: string);
begin
  if FProgressShown then
    ClearProgressLine;

  WriteLn(ALine);
end;

end.
