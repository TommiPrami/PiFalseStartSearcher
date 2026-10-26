unit PFSUnit.RunLog.Memo;

interface

uses
  System.Classes, Vcl.StdCtrls, PFSUnit.FalseStartSearch, PFSUnit.RunLog;

type
  // Lines to a memo, progress to a label. Does not own them.
  TPFSMemoRunLog = class(TPFSRunLog)
  strict private
    FMemo: TMemo;
    FProgressLabel: TLabel;
  strict protected
    procedure WriteLine(const ALine: string); override;
    procedure WriteLines(const ALines: TStrings); override;
  public
    constructor Create(const AMemo: TMemo; const AProgressLabel: TLabel);

    procedure Clear; override;
    procedure ShowProgress(const AProgress: TPFSProgress); override;
  end;

implementation

uses
  PFSUnit.Report;

{ TPFSMemoRunLog }

constructor TPFSMemoRunLog.Create(const AMemo: TMemo; const AProgressLabel: TLabel);
begin
  inherited Create;

  FMemo := AMemo;
  FProgressLabel := AProgressLabel;
end;

procedure TPFSMemoRunLog.Clear;
begin
  FMemo.Clear;
  FProgressLabel.Caption := '';
end;

procedure TPFSMemoRunLog.ShowProgress(const AProgress: TPFSProgress);
begin
  FProgressLabel.Caption := FormatProgress(AProgress);
end;

procedure TPFSMemoRunLog.WriteLine(const ALine: string);
begin
  FMemo.Lines.Add(ALine);
end;

procedure TPFSMemoRunLog.WriteLines(const ALines: TStrings);
begin
  // In one go, TMemo gets very slow when many lines are added one by one
  FMemo.SelStart := FMemo.GetTextLen;
  FMemo.SelText := ALines.Text;
end;

end.
