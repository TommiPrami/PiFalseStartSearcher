unit PFSForm.Main;

interface

uses
  Winapi.Messages, Winapi.Windows, System.Classes, System.Generics.Collections, System.SysUtils, System.Threading,
  System.UITypes, System.Variants, Vcl.Controls, Vcl.Dialogs, Vcl.ExtCtrls, Vcl.Forms, Vcl.Graphics, Vcl.StdCtrls,
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
    ButtonValidateFIle: TButton;
    ButtonMakeValidFile: TButton;
    procedure ButtonMakeValidFileClick(Sender: TObject);
    procedure ButtonValidateFIleClick(Sender: TObject);
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

procedure TPFSMainForm.ButtonMakeValidFileClick(Sender: TObject);
begin
  raise Exception.Create('"ButtonMakeValidFileClick" - Not Implemented Yet');
end;

function IntToStrTS(const AValue: UInt64; const ASeparator: Char = ' '): string;
var
  LThirdOfLength, LRemainder, LIndex: Integer;
  LPosition, LStep: Integer;
  LLength: Integer;
begin
  Result := IntToStr(AValue);

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

procedure TPFSMainForm.ButtonValidateFIleClick(Sender: TObject);
const
  READ_BUFFER_SIZE = 1024 * 1024;
  STREAM_BFFER_SIZE = READ_BUFFER_SIZE * 32;
begin
  Screen.Cursor := crHourGlass;
  var LBuffer: TArray<AnsiChar> := [];
  SetLength(LBuffer, READ_BUFFER_SIZE);

  var LBytesRead: LongInt := 5;
  var LFileStream := TBufferedFileSTream.Create(EditFileName.Text, fmOpenRead or fmShareDenyWrite, STREAM_BFFER_SIZE);
  try
    while LBytesRead > 0 do
    begin
      LBytesRead := LFileStream.Read(LBuffer[0], READ_BUFFER_SIZE);

      for var LIndex := 0 to LBytesRead - 1 do
        if not (LBuffer[LIndex] in ['0'..'9', '.']) then
        begin
          MessageDlg('File ' + string(EditFileName.Text).QuotedString('"') + ' contains nonvalid characters like: ' +
            IntToHex(Ord(LBuffer[LIndex])), mtError, [mbOK], 0);

          Exit;
        end;
    end;
  finally
    LFileStream .Free;
    Screen.Cursor := crDefault;
  end;
end;

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
  MemoLog.Lines.Add('Pos: ' + IntToStrTS(APosition) + ' - "' + string(AMatchedValue) + '"');
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
