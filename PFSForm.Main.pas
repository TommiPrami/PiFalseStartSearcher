unit PFSForm.Main;

interface

uses
  Winapi.Windows, Winapi.Messages, System.SysUtils, System.Variants, System.Classes, Vcl.Graphics,
  Vcl.Controls, Vcl.Forms, Vcl.Dialogs, Vcl.StdCtrls, System.Generics.Collections, System.Threading, Vcl.ExtCtrls,
  PFSUnit.FalseRestartSearch;

type
  TPFSMainForm = class(TForm)
    TimerProgress: TTimer;
    Panel1: TPanel;
    ButtonRun: TButton;
    Panel2: TPanel;
    EditFileName: TEdit;
    MemoLog: TMemo;
    ButtonStopRun: TButton;
    procedure ButtonRunClick(Sender: TObject);
    procedure ButtonStopRunClick(Sender: TObject);
    procedure FormCreate(Sender: TObject);
    procedure TimerProgressTimer(Sender: TObject);
  strict private
    FPiSearcher: TPiFalseRestartSearcher;
    procedure FalseRestartFound(const ASender: TObject; const APosition: Int64; const AMatchedValue: AnsiString);
    procedure TaskEndedEvent(const APiSearcher: TPiFalseRestartSearcher);
  end;

var
  PFSMainForm: TPFSMainForm;

implementation

{$R *.dfm}

{ TPFSMainForm }

procedure TPFSMainForm.FormCreate(Sender: TObject);
begin
  FPiSearcher := nil;
end;

procedure TPFSMainForm.ButtonRunClick(Sender: TObject);
begin
  if Assigned(FPiSearcher) then
    Exit;

  (Sender as TButton).Enabled := False;
  ButtonStopRun.Enabled := True;
  TimerProgress.Enabled := True;
  MemoLog.Clear;

  FPiSearcher := TPiFalseRestartSearcher.Create(FalseRestartFound, TaskEndedEvent, True);
  FPiSearcher.Execute(EditFileName.Text);
end;

procedure TPFSMainForm.ButtonStopRunClick(Sender: TObject);
begin
  if Assigned(FPiSearcher) then
    FPiSearcher.Cancel;
end;

procedure TPFSMainForm.FalseRestartFound(const ASender: TObject; const APosition: Int64; const AMatchedValue: AnsiString);
begin
  MemoLog.Lines.Add('Pos: ' + APosition.ToString + ' - "' + string(AMatchedValue) + '"');
end;

procedure TPFSMainForm.TaskEndedEvent(const APiSearcher: TPiFalseRestartSearcher);

  function GetElapsedStr(const APiSearcher: TPiFalseRestartSearcher): string;
  begin
    Result := FormatFloat('0.00', APiSearcher.ElapsedSeconds) + 's';
  end;

begin
  MemoLog.Lines.Add('');

  if APiSearcher.Status = rsCanceled then
    MemoLog.Lines.Add('Run canceled. At running time ' + GetElapsedStr(APiSearcher))
  else if APiSearcher.Status = rsError then
    MemoLog.Lines.Add('Error occured. At running time ' + GetElapsedStr(APiSearcher))
  else
    MemoLog.Lines.Add('Run finished. It took us ' + GetElapsedStr(APiSearcher));

  ButtonRun.Enabled := True;
  ButtonStopRun.Enabled := not ButtonRun.Enabled;
end;

procedure TPFSMainForm.TimerProgressTimer(Sender: TObject);
begin
  if not Assigned(FPiSearcher) then
    Exit;

  if FPiSearcher.HasRunEndedStatus and ButtonRun.Enabled then
  begin
    FreeAndNil(FPiSearcher);
    TimerProgress.Enabled := False;
  end;
end;

end.
