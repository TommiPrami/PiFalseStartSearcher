unit PFSUnit.FalseStartSearch;

(*
  Pi false start search
  =====================

  A false start of length L at position P means that the L digits starting at
  decimal position P are the same as the first L digits of the file, integer
  part included ("31415926...").

  The prefix is read from the beginning of the first file, so the same search
  works for any constant whose digits are in a text file. Positions follow the
  usual Pi search convention: the first digit after the decimal point is at
  position 1. For example "314159" is first found at position 176 451.

  Every start position is checked independently: the four first digits are
  compared at once against the prefix, and only on a hit (about once in 10 000
  positions) the match is extended digit by digit. Because positions are
  independent, each buffer is split into slices that are scanned in parallel,
  and the next buffer is read while the current one is scanned. A buffer keeps
  the last (prefix length - 1) digits of the previous one in front of it, so a
  match spanning a buffer or file boundary is seen whole and only once.

  Characters other than digits (the decimal point, line breaks) are skipped, so
  digit files with line breaks work too.
*)

interface

uses
  System.Classes, System.Diagnostics, System.Generics.Collections, System.SyncObjs, System.SysUtils, System.Threading;

const
  // A longer list would only choke the log, the statistics have the counts of all of them
  MAX_LISTED_FALSE_STARTS = 1000;
  MAX_PATTERN_LENGTH = 64;
  // Same as SizeOf(Cardinal), the first digits are compared as one Cardinal
  MIN_MATCH_LENGTH = 4;

type
  TPiFalseStartSearcher = class;

  // mkNewLongest = the first false start longer than any found before it
  TPFSMatchKind = (mkFalseStart, mkNewLongest, mkSelfLocating);

  TPFSMatch = record
    Kind: TPFSMatchKind;
    Length: Integer;
    Position: Int64;
  end;

  TPFSLengthStatistic = record
    Count: Int64;
    FirstPosition: Int64;
  end;

  // Indexed by the exact match length
  TPFSLengthStatistics = array[0..MAX_PATTERN_LENGTH] of TPFSLengthStatistic;

  TPFSMatchEvent = procedure(const APiSearcher: TPiFalseStartSearcher; const AMatch: TPFSMatch) of object;

  TPFSProgress = record
    BytesRead: Int64;
    BytesTotal: Int64;
    DigitsScanned: Int64;
    ElapsedSeconds: Double;
    LongestMatch: Integer;
  end;

  TPFSSearchEndedEvent = procedure(const APiSearcher: TPiFalseStartSearcher) of object;

  TPFSSliceResult = record
    Matches: TArray<TPFSMatch>;
    Statistics: TPFSLengthStatistics;
  end;

  TRunStatus = (rsNone, rsRunning, rsCanceled, rsError, rsFinished);

  // Reads the files one after another and hands out only the digits
  TPFSDigitFileReader = class(TObject)
  strict private
    FBytesRead: Int64;
    FBytesTotal: Int64;
    FFileIndex: Integer;
    FFileNames: TArray<string>;
    FFileOffset: Int64;
    FFirstUnexpectedChar: string;
    FHandle: THandle;
    FNonDigitCount: Int64;
    FUnexpectedCharCount: Int64;
    function GetBytesRead: Int64;
    function OpenNextFile: Boolean;
    procedure CloseCurrentFile;
    procedure CompactDigits(const ABuffer: PByte; var ACount: Integer);
    procedure NonDigitFound(const AValue: Byte; const AFileOffset: Int64);
  public
    constructor Create(const AFileNames: TArray<string>);
    destructor Destroy; override;

    // Fills ABuffer with the next digits, other characters are dropped. Returns False when all files are read.
    function ReadDigits(const ABuffer: PByte; const ACapacity: Integer; var ADigitCount: Integer): Boolean;
    property BytesRead: Int64 read GetBytesRead;
    property BytesTotal: Int64 read FBytesTotal;
    property FirstUnexpectedChar: string read FFirstUnexpectedChar;
    property NonDigitCount: Int64 read FNonDigitCount;
    property UnexpectedCharCount: Int64 read FUnexpectedCharCount;
  end;

  TPiFalseStartSearcher = class(TObject)
  strict private
    FBufferSize: Integer;
    FDigitsScanned: Int64;
    FErrorMessage: string;
    FFileNames: TArray<string>;
    FIntegerDigits: Integer;
    FListedFalseStartCount: Integer;
    FListMatchLength: Integer;
    FLock: TCriticalSection;
    FLongestMatch: Integer;
    FMatches: TList<TPFSMatch>;
    FMinMatchLength: Integer;
    FNextDigitCount: Integer;
    FNextHasData: Boolean;
    FOnlyNewLongestMatches: Boolean;
    FOnMatch: TPFSMatchEvent;
    FOnSearchEnded: TPFSSearchEndedEvent;
    FPattern: TBytes;
    FPatternLength: Integer;
    FReader: TPFSDigitFileReader;
    FSearchSelfLocating: Boolean;
    FStatistics: TPFSLengthStatistics;
    FStatus: TRunStatus;
    FStopwatch: TStopwatch;
    FThread: TThread;
    function DigitIndexToPosition(const ADigitIndex: Int64): Int64; inline;
    function GetErrorMessage: string;
    function GetFirstUnexpectedChar: string;
    function GetNonDigitCount: Int64;
    function GetPatternText: string;
    function GetProgress: TPFSProgress;
    function GetStatus: TRunStatus;
    function GetUnexpectedCharCount: Int64;
    function StartReadTask(const ABuffer: PByte): ITask;
    procedure AddFalseStart(const AData: PByte; const ADataLength, AIndex: Integer; const ADigitBase: Int64;
      var AResult: TPFSSliceResult);
    procedure AddNewLongestMatches(const AStatistics: TPFSLengthStatistics);
    procedure FinishRun(const AStatus: TRunStatus; const AErrorMessage: string);
    procedure LoadPattern(const AFileName: string);
    procedure MergeSliceResults(const AResults: TArray<TPFSSliceResult>; const AScanCount: Integer);
    procedure QueueMatch(const AMatch: TPFSMatch);
    procedure ScanBuffer(const AData: PByte; const ADataLength, AScanCount: Integer; const ADigitBase: Int64);
    procedure ScanSlice(const AData: PByte; const ADataLength, AFrom, ATo: Integer; const ADigitBase: Int64;
      var AResult: TPFSSliceResult);
    procedure Search;
    procedure SearchSelfLocatingStrings(const AData: PByte; const ADataLength, AFrom, ATo: Integer; const ADigitBase: Int64;
      var AResult: TPFSSliceResult);
    procedure SearchThreadProc;
    procedure ValidateSettings;
  public
    constructor Create(const AOnMatch: TPFSMatchEvent; const AOnSearchEnded: TPFSSearchEndedEvent);
    destructor Destroy; override;

    // Returns AFileName and the files that continue it, pi_dec_1t_01.txt -> pi_dec_1t_02.txt etc., as long as they exist
    class function FindContinuationFiles(const AFileName: string): TArray<string>;
    function GetMatches: TArray<TPFSMatch>;
    function GetStatistics: TPFSLengthStatistics;
    function HasRunEndedStatus: Boolean;
    procedure Cancel;
    // Starts the search in a background thread. Raises on invalid settings or missing files. A searcher runs only once.
    procedure Execute(const AFileNames: TArray<string>);
    // Read-buffer size in bytes. Default = 64 MB. Does not affect which matches are found.
    property BufferSize: Integer read FBufferSize write FBufferSize;
    property ErrorMessage: string read GetErrorMessage;
    property FileNames: TArray<string> read FFileNames;
    property FirstUnexpectedChar: string read GetFirstUnexpectedChar;
    // Matches at least this long are listed in GetMatches, and reported one by one with OnMatch unless
    // OnlyNewLongestMatches is set. Only the first MAX_LISTED_FALSE_STARTS are listed, the statistics have the counts.
    // Default = 10.
    property ListMatchLength: Integer read FListMatchLength write FListMatchLength;
    // Matches shorter than this are not counted. Default and minimum = MIN_MATCH_LENGTH.
    property MinMatchLength: Integer read FMinMatchLength write FMinMatchLength;
    property NonDigitCount: Int64 read GetNonDigitCount;
    // OnMatch fires only for a new longest false start (mkNewLongest), a quiet log. All matches are still in GetMatches.
    // Default = True.
    property OnlyNewLongestMatches: Boolean read FOnlyNewLongestMatches write FOnlyNewLongestMatches;
    property OnMatch: TPFSMatchEvent read FOnMatch write FOnMatch;
    property OnSearchEnded: TPFSSearchEndedEvent read FOnSearchEnded write FOnSearchEnded;
    property PatternText: string read GetPatternText;
    property Progress: TPFSProgress read GetProgress;
    // Also look for self-locating strings, the digits at position P spell P (for example "16470" at position 16 470)
    property SearchSelfLocating: Boolean read FSearchSelfLocating write FSearchSelfLocating;
    property Status: TRunStatus read GetStatus;
    property UnexpectedCharCount: Int64 read GetUnexpectedCharCount;
  end;

implementation

uses
  Winapi.Windows, System.Generics.Defaults, System.IOUtils, System.Math;

const
  DEFAULT_BUFFER_SIZE = 64 * 1024 * 1024;
  DEFAULT_LIST_MATCH_LENGTH = 10;
  DIGIT_HIGH_NIBBLES: UInt64 = $3030303030303030;
  HIGH_NIBBLE_MASK: UInt64 = $F0F0F0F0F0F0F0F0;
  LOW_NIBBLE_MASK: UInt64 = $0F0F0F0F0F0F0F0F;
  LOW_NIBBLE_OVERFLOW: UInt64 = $0606060606060606;
  SLICE_SIZE = 1024 * 1024;

type
  TPFSPositionText = array[0..23] of Byte;

procedure IncrementPositionText(var AText: TPFSPositionText; var ALength: Integer);
var
  LIndex: Integer;
begin
  LIndex := ALength - 1;

  while (LIndex >= 0) and (AText[LIndex] = Ord('9')) do
  begin
    AText[LIndex] := Ord('0');
    Dec(LIndex);
  end;

  if LIndex >= 0 then
    Inc(AText[LIndex])
  else
  begin
    Move(AText[0], AText[1], ALength);
    AText[0] := Ord('1');
    Inc(ALength);
  end;
end;

// True when all eight bytes are ASCII digits
function IsAllDigits(const AValue: UInt64): Boolean; inline;
begin
  Result := ((AValue and HIGH_NIBBLE_MASK) = DIGIT_HIGH_NIBBLES)
    and ((((AValue and LOW_NIBBLE_MASK) + LOW_NIBBLE_OVERFLOW) and HIGH_NIBBLE_MASK) = 0);
end;

function PositionToText(const APosition: Int64; var AText: TPFSPositionText): Integer;
var
  LText: AnsiString;
begin
  LText := AnsiString(IntToStr(APosition));
  Result := Length(LText);

  Move(LText[1], AText[0], Result);
end;

procedure WaitForTask(const ATask: ITask);
begin
  try
    ATask.Wait;
  except
    on E: EAggregateException do
    begin
      if E.Count > 0 then
        raise Exception.Create(E.InnerExceptions[0].Message);

      raise;
    end;
  end;
end;

{ TPFSDigitFileReader }

constructor TPFSDigitFileReader.Create(const AFileNames: TArray<string>);
begin
  inherited Create;

  FFileNames := Copy(AFileNames);
  FFileIndex := -1;
  FHandle := INVALID_HANDLE_VALUE;

  for var LFileName in FFileNames do
  begin
    if not FileExists(LFileName) then
      raise EFileNotFoundException.CreateFmt('File "%s" not found', [LFileName]);

    Inc(FBytesTotal, TFile.GetSize(LFileName));
  end;
end;

destructor TPFSDigitFileReader.Destroy;
begin
  CloseCurrentFile;

  inherited Destroy;
end;

function TPFSDigitFileReader.GetBytesRead: Int64;
begin
  Result := TInterlocked.Read(FBytesRead);
end;

function TPFSDigitFileReader.OpenNextFile: Boolean;
begin
  Inc(FFileIndex);
  Result := FFileIndex < Length(FFileNames);

  if not Result then
    Exit;

  FHandle := CreateFile(PChar(FFileNames[FFileIndex]), GENERIC_READ, FILE_SHARE_READ, nil, OPEN_EXISTING,
    FILE_FLAG_SEQUENTIAL_SCAN, 0);

  if FHandle = INVALID_HANDLE_VALUE then
    RaiseLastOSError;

  FFileOffset := 0;
end;

function TPFSDigitFileReader.ReadDigits(const ABuffer: PByte; const ACapacity: Integer; var ADigitCount: Integer): Boolean;
var
  LBytesRead: DWORD;
begin
  ADigitCount := 0;

  while True do
  begin
    if (FHandle = INVALID_HANDLE_VALUE) and not OpenNextFile then
      Exit(False);

    if not ReadFile(FHandle, ABuffer^, ACapacity, LBytesRead, nil) then
      RaiseLastOSError;

    if LBytesRead > 0 then
      Break;

    CloseCurrentFile;
  end;

  ADigitCount := LBytesRead;
  CompactDigits(ABuffer, ADigitCount);

  Inc(FFileOffset, LBytesRead);
  TInterlocked.Add(FBytesRead, Int64(LBytesRead));

  Result := True;
end;

procedure TPFSDigitFileReader.CloseCurrentFile;
begin
  if FHandle <> INVALID_HANDLE_VALUE then
  begin
    CloseHandle(FHandle);
    FHandle := INVALID_HANDLE_VALUE;
  end;
end;

procedure TPFSDigitFileReader.CompactDigits(const ABuffer: PByte; var ACount: Integer);
var
  LByte: Byte;
  LReadIndex: Integer;
  LWriteIndex: Integer;
begin
  LReadIndex := 0;

  // Fast path, the files are usually digits only
  while (LReadIndex <= ACount - SizeOf(UInt64)) and IsAllDigits(PUInt64(ABuffer + LReadIndex)^) do
    Inc(LReadIndex, SizeOf(UInt64));

  LWriteIndex := LReadIndex;

  while LReadIndex < ACount do
  begin
    LByte := ABuffer[LReadIndex];

    if (LByte >= Ord('0')) and (LByte <= Ord('9')) then
    begin
      ABuffer[LWriteIndex] := LByte;
      Inc(LWriteIndex);
    end
    else
      NonDigitFound(LByte, FFileOffset + LReadIndex);

    Inc(LReadIndex);
  end;

  ACount := LWriteIndex;
end;

procedure TPFSDigitFileReader.NonDigitFound(const AValue: Byte; const AFileOffset: Int64);
begin
  Inc(FNonDigitCount);

  // Decimal point and white space are expected, anything else hints at a broken file
  if AValue in [Ord('.'), 9, 10, 13, 32] then
    Exit;

  if FUnexpectedCharCount = 0 then
    FFirstUnexpectedChar := Format('$%.2x at byte offset %d of "%s"', [AValue, AFileOffset, FFileNames[FFileIndex]]);

  Inc(FUnexpectedCharCount);
end;

{ TPiFalseStartSearcher }

constructor TPiFalseStartSearcher.Create(const AOnMatch: TPFSMatchEvent; const AOnSearchEnded: TPFSSearchEndedEvent);
begin
  inherited Create;

  FLock := TCriticalSection.Create;
  FMatches := TList<TPFSMatch>.Create;
  FOnMatch := AOnMatch;
  FOnSearchEnded := AOnSearchEnded;
  FStatus := rsNone;
  FBufferSize := DEFAULT_BUFFER_SIZE;
  FListMatchLength := DEFAULT_LIST_MATCH_LENGTH;
  FMinMatchLength := MIN_MATCH_LENGTH;
  FOnlyNewLongestMatches := True;
  FSearchSelfLocating := False;
end;

destructor TPiFalseStartSearcher.Destroy;
begin
  // Queued events still run while waiting below, they must not call the owner anymore
  FOnMatch := nil;
  FOnSearchEnded := nil;

  Cancel;

  if Assigned(FThread) then
  begin
    FThread.WaitFor;
    // Also removes the events the thread still has in the queue
    FThread.Free;
  end;

  FReader.Free;
  FMatches.Free;
  FLock.Free;

  inherited Destroy;
end;

function TPiFalseStartSearcher.DigitIndexToPosition(const ADigitIndex: Int64): Int64;
begin
  Result := ADigitIndex - FIntegerDigits + 1;
end;

class function TPiFalseStartSearcher.FindContinuationFiles(const AFileName: string): TArray<string>;
var
  LBaseName: string;
  LDigitCount: Integer;
  LDigitStart: Integer;
  LFileName: string;
  LNumber: Integer;
begin
  Result := [AFileName];

  LBaseName := TPath.GetFileNameWithoutExtension(AFileName);
  LDigitStart := Length(LBaseName);

  while (LDigitStart >= 1) and CharInSet(LBaseName[LDigitStart], ['0'..'9']) do
    Dec(LDigitStart);

  LDigitCount := Length(LBaseName) - LDigitStart;

  if (LDigitCount = 0) or (LDigitCount > 9) then
    Exit;

  LNumber := StrToInt(Copy(LBaseName, LDigitStart + 1, LDigitCount));
  LBaseName := Copy(LBaseName, 1, LDigitStart);

  while True do
  begin
    Inc(LNumber);
    LFileName := TPath.Combine(TPath.GetDirectoryName(AFileName),
      LBaseName + IntToStr(LNumber).PadLeft(LDigitCount, '0') + TPath.GetExtension(AFileName));

    if not FileExists(LFileName) then
      Break;

    Result := Result + [LFileName];
  end;
end;

function TPiFalseStartSearcher.GetErrorMessage: string;
begin
  FLock.Acquire;
  try
    Result := FErrorMessage;
  finally
    FLock.Release;
  end;
end;

function TPiFalseStartSearcher.GetFirstUnexpectedChar: string;
begin
  Result := '';

  if Assigned(FReader) and HasRunEndedStatus then
    Result := FReader.FirstUnexpectedChar;
end;

function TPiFalseStartSearcher.GetMatches: TArray<TPFSMatch>;
begin
  FLock.Acquire;
  try
    Result := FMatches.ToArray;
  finally
    FLock.Release;
  end;
end;

function TPiFalseStartSearcher.GetNonDigitCount: Int64;
begin
  Result := 0;

  if Assigned(FReader) and HasRunEndedStatus then
    Result := FReader.NonDigitCount;
end;

function TPiFalseStartSearcher.GetPatternText: string;
begin
  Result := string(TEncoding.ANSI.GetString(FPattern));
end;

function TPiFalseStartSearcher.GetProgress: TPFSProgress;
begin
  Result := Default(TPFSProgress);

  if Assigned(FReader) then
  begin
    Result.BytesRead := FReader.BytesRead;
    Result.BytesTotal := FReader.BytesTotal;
  end;

  FLock.Acquire;
  try
    Result.DigitsScanned := FDigitsScanned;
    Result.ElapsedSeconds := FStopwatch.Elapsed.TotalSeconds;
    Result.LongestMatch := FLongestMatch;
  finally
    FLock.Release;
  end;
end;

function TPiFalseStartSearcher.GetStatistics: TPFSLengthStatistics;
begin
  FLock.Acquire;
  try
    Result := FStatistics;
  finally
    FLock.Release;
  end;
end;

function TPiFalseStartSearcher.GetStatus: TRunStatus;
begin
  FLock.Acquire;
  try
    Result := FStatus;
  finally
    FLock.Release;
  end;
end;

function TPiFalseStartSearcher.GetUnexpectedCharCount: Int64;
begin
  Result := 0;

  if Assigned(FReader) and HasRunEndedStatus then
    Result := FReader.UnexpectedCharCount;
end;

function TPiFalseStartSearcher.HasRunEndedStatus: Boolean;
begin
  Result := GetStatus in [rsCanceled, rsError, rsFinished];
end;

function TPiFalseStartSearcher.StartReadTask(const ABuffer: PByte): ITask;
begin
  Result := TTask.Run(
    procedure
    begin
      FNextHasData := FReader.ReadDigits(ABuffer, FBufferSize, FNextDigitCount);
    end
  );
end;

procedure TPiFalseStartSearcher.AddFalseStart(const AData: PByte; const ADataLength, AIndex: Integer; const ADigitBase: Int64;
  var AResult: TPFSSliceResult);
var
  LDigitIndex: Int64;
  LLength: Integer;
  LLimit: Integer;
  LMatch: TPFSMatch;
begin
  LDigitIndex := ADigitBase + AIndex;

  // The searched prefix itself is not a false start
  if LDigitIndex = 0 then
    Exit;

  LLimit := Min(FPatternLength, ADataLength - AIndex);
  LLength := MIN_MATCH_LENGTH;

  while (LLength < LLimit) and (AData[AIndex + LLength] = FPattern[LLength]) do
    Inc(LLength);

  if LLength < FMinMatchLength then
    Exit;

  if AResult.Statistics[LLength].Count = 0 then
    AResult.Statistics[LLength].FirstPosition := DigitIndexToPosition(LDigitIndex);

  Inc(AResult.Statistics[LLength].Count);

  if LLength >= FListMatchLength then
  begin
    LMatch.Kind := mkFalseStart;
    LMatch.Length := LLength;
    LMatch.Position := DigitIndexToPosition(LDigitIndex);

    AResult.Matches := AResult.Matches + [LMatch];
  end;
end;

// A new longest match is always the first one of its length, so the first positions of the slice are enough. Called
// with FLock held.
procedure TPiFalseStartSearcher.AddNewLongestMatches(const AStatistics: TPFSLengthStatistics);
var
  LCandidates: TArray<TPFSMatch>;
  LLongest: Integer;
  LMatch: TPFSMatch;
begin
  LCandidates := [];

  for var LLength := Max(FLongestMatch + 1, FMinMatchLength) to FPatternLength do
    if AStatistics[LLength].Count > 0 then
    begin
      LMatch.Kind := mkNewLongest;
      LMatch.Length := LLength;
      LMatch.Position := AStatistics[LLength].FirstPosition;

      LCandidates := LCandidates + [LMatch];
    end;

  if Length(LCandidates) = 0 then
    Exit;

  TArray.Sort<TPFSMatch>(LCandidates, TComparer<TPFSMatch>.Construct(
    function(const ALeft, ARight: TPFSMatch): Integer
    begin
      Result := CompareValue(ALeft.Position, ARight.Position);
    end
  ));

  // In position order, a candidate is a new longest only if it beats everything before it
  LLongest := FLongestMatch;

  for LMatch in LCandidates do
    if LMatch.Length > LLongest then
    begin
      LLongest := LMatch.Length;
      FMatches.Add(LMatch);

      if FOnlyNewLongestMatches then
        QueueMatch(LMatch);
    end;
end;

procedure TPiFalseStartSearcher.Cancel;
begin
  FLock.Acquire;
  try
    if FStatus in [rsNone, rsRunning] then
      FStatus := rsCanceled;
  finally
    FLock.Release;
  end;
end;

procedure TPiFalseStartSearcher.Execute(const AFileNames: TArray<string>);
begin
  if GetStatus <> rsNone then
    raise EInvalidOpException.Create('A searcher runs only once, create a new one for the next run');

  if Length(AFileNames) = 0 then
    raise EArgumentException.Create('No files to search');

  ValidateSettings;

  FFileNames := Copy(AFileNames);
  FReader := TPFSDigitFileReader.Create(FFileNames);
  LoadPattern(FFileNames[0]);

  FThread := TThread.CreateAnonymousThread(
    procedure
    begin
      SearchThreadProc;
    end
  );
  FThread.FreeOnTerminate := False;

  FLock.Acquire;
  try
    FStatus := rsRunning;
    FStopwatch := TStopwatch.StartNew;
  finally
    FLock.Release;
  end;

  FThread.Start;
end;

procedure TPiFalseStartSearcher.FinishRun(const AStatus: TRunStatus; const AErrorMessage: string);
begin
  FLock.Acquire;
  try
    FStopwatch.Stop;

    // A canceled run stays canceled, unless it failed
    if (FStatus = rsRunning) or (AStatus = rsError) then
      FStatus := AStatus;

    FErrorMessage := AErrorMessage;
  finally
    FLock.Release;
  end;
end;

procedure TPiFalseStartSearcher.LoadPattern(const AFileName: string);
const
  HEADER_SIZE = 4096;
var
  LDigitCount: Integer;
  LDigits: TBytes;
  LHeader: TBytes;
  LHeaderLength: Integer;
  LIntegerDigits: Integer;
begin
  SetLength(LHeader, HEADER_SIZE);

  var LFileStream := TFileStream.Create(AFileName, fmOpenRead or fmShareDenyWrite);
  try
    LHeaderLength := LFileStream.Read(LHeader[0], HEADER_SIZE);
  finally
    LFileStream.Free;
  end;

  SetLength(LDigits, LHeaderLength);
  LDigitCount := 0;
  LIntegerDigits := -1;

  for var LIndex := 0 to LHeaderLength - 1 do
    case LHeader[LIndex] of
      Ord('0')..Ord('9'):
        begin
          LDigits[LDigitCount] := LHeader[LIndex];
          Inc(LDigitCount);
        end;
      Ord('.'):
        if LIntegerDigits < 0 then
          LIntegerDigits := LDigitCount;
    end;

  // Without a decimal point the file holds only decimals
  FIntegerDigits := Max(LIntegerDigits, 0);
  FPatternLength := Min(MAX_PATTERN_LENGTH, LDigitCount);

  if FPatternLength < FMinMatchLength then
    raise EArgumentException.CreateFmt('File "%s" starts with %d digits, at least %d are needed',
      [AFileName, FPatternLength, FMinMatchLength]);

  FPattern := Copy(LDigits, 0, FPatternLength);
end;

procedure TPiFalseStartSearcher.MergeSliceResults(const AResults: TArray<TPFSSliceResult>; const AScanCount: Integer);
begin
  FLock.Acquire;
  try
    // Slices are merged in order, so the first slice with a match has the first position
    for var LIndex := 0 to High(AResults) do
    begin
      // Before the statistics below raise FLongestMatch
      AddNewLongestMatches(AResults[LIndex].Statistics);

      for var LLength := FMinMatchLength to FPatternLength do
      begin
        var LCount := AResults[LIndex].Statistics[LLength].Count;

        if LCount = 0 then
          Continue;

        if FStatistics[LLength].Count = 0 then
          FStatistics[LLength].FirstPosition := AResults[LIndex].Statistics[LLength].FirstPosition;

        Inc(FStatistics[LLength].Count, LCount);

        if LLength > FLongestMatch then
          FLongestMatch := LLength;
      end;

      for var LMatch in AResults[LIndex].Matches do
      begin
        if LMatch.Kind = mkFalseStart then
        begin
          if FListedFalseStartCount >= MAX_LISTED_FALSE_STARTS then
            Continue;

          Inc(FListedFalseStartCount);
        end;

        FMatches.Add(LMatch);

        if not FOnlyNewLongestMatches then
          QueueMatch(LMatch);
      end;
    end;

    Inc(FDigitsScanned, AScanCount);
  finally
    FLock.Release;
  end;
end;

procedure TPiFalseStartSearcher.QueueMatch(const AMatch: TPFSMatch);
begin
  TThread.Queue(FThread,
    procedure
    begin
      if Assigned(FOnMatch) then
        FOnMatch(Self, AMatch);
    end
  );
end;

// Scans the start positions 0..AScanCount - 1, ADataLength may be larger to give the last positions their lookahead
procedure TPiFalseStartSearcher.ScanBuffer(const AData: PByte; const ADataLength, AScanCount: Integer; const ADigitBase: Int64);
var
  LResults: TArray<TPFSSliceResult>;
  LSliceCount: Integer;
begin
  if AScanCount <= 0 then
    Exit;

  LSliceCount := (AScanCount + SLICE_SIZE - 1) div SLICE_SIZE;
  SetLength(LResults, LSliceCount);

  if LSliceCount = 1 then
    ScanSlice(AData, ADataLength, 0, AScanCount, ADigitBase, LResults[0])
  else
    TParallel.for(0, LSliceCount - 1,
      procedure(AIndex: Integer)
      begin
        ScanSlice(AData, ADataLength, AIndex * SLICE_SIZE, Min((AIndex + 1) * SLICE_SIZE, AScanCount), ADigitBase,
          LResults[AIndex]);
      end
    );

  MergeSliceResults(LResults, AScanCount);
end;

procedure TPiFalseStartSearcher.ScanSlice(const AData: PByte; const ADataLength, AFrom, ATo: Integer; const ADigitBase: Int64;
  var AResult: TPFSSliceResult);
var
  LCandidate: PByte;
  LEnd: PByte;
  LPrefix: Cardinal;
begin
  LPrefix := PCardinal(@FPattern[0])^;
  LCandidate := AData + AFrom;
  // Closer than MIN_MATCH_LENGTH digits to the end of data there is no room for a match
  LEnd := AData + Min(ATo, ADataLength - MIN_MATCH_LENGTH + 1);

  while LCandidate < LEnd do
  begin
    if PCardinal(LCandidate)^ = LPrefix then
      AddFalseStart(AData, ADataLength, Integer(LCandidate - AData), ADigitBase, AResult);

    Inc(LCandidate);
  end;

  if FSearchSelfLocating then
    SearchSelfLocatingStrings(AData, ADataLength, AFrom, ATo, ADigitBase, AResult);
end;

procedure TPiFalseStartSearcher.Search;
var
  LBuffers: array[0..1] of TBytes;
  LCarryLength: Integer;
  LCurrent: Integer;
  LData: PByte;
  LDigitBase: Int64;
  LDigitCount: Integer;
  LHasData: Boolean;
  LReadTask: ITask;
  LReserve: Integer;
  LScanCount: Integer;
  LUsed: Integer;
begin
  // Room in front of the read area for the digits carried over from the previous buffer
  LReserve := FPatternLength - 1;

  for LCurrent := Low(LBuffers) to High(LBuffers) do
    SetLength(LBuffers[LCurrent], LReserve + FBufferSize);

  LCurrent := 0;
  LCarryLength := 0;
  LDigitBase := 0;
  LHasData := FReader.ReadDigits(@LBuffers[LCurrent][LReserve], FBufferSize, LDigitCount);

  while LHasData and not HasRunEndedStatus do
  begin
    LData := @LBuffers[LCurrent][LReserve - LCarryLength];
    LUsed := LCarryLength + LDigitCount;

    LReadTask := StartReadTask(@LBuffers[1 - LCurrent][LReserve]);
    try
      // Only positions with a full prefix length of lookahead, the rest are carried to the next buffer
      LScanCount := Max(0, LUsed - FPatternLength + 1);
      ScanBuffer(LData, LUsed, LScanCount, LDigitBase);
    finally
      WaitForTask(LReadTask);
    end;

    LCarryLength := LUsed - LScanCount;

    if LCarryLength > 0 then
      Move(LData[LScanCount], LBuffers[1 - LCurrent][LReserve - LCarryLength], LCarryLength);

    Inc(LDigitBase, LScanCount);
    LCurrent := 1 - LCurrent;
    LHasData := FNextHasData;
    LDigitCount := FNextDigitCount;
  end;

  // The last digits of the last file
  if not HasRunEndedStatus then
    ScanBuffer(@LBuffers[LCurrent][LReserve - LCarryLength], LCarryLength, LCarryLength, LDigitBase);
end;

procedure TPiFalseStartSearcher.SearchSelfLocatingStrings(const AData: PByte; const ADataLength, AFrom, ATo: Integer;
  const ADigitBase: Int64; var AResult: TPFSSliceResult);
var
  LIndex: Integer;
  LMatch: TPFSMatch;
  LPosition: Int64;
  LText: TPFSPositionText;
  LTextLength: Integer;
begin
  LIndex := AFrom;
  LPosition := DigitIndexToPosition(ADigitBase + AFrom);

  // The integer part has no position
  if LPosition < 1 then
  begin
    LIndex := LIndex + Integer(1 - LPosition);
    LPosition := 1;
  end;

  LTextLength := PositionToText(LPosition, LText);

  while LIndex < ATo do
  begin
    if (AData[LIndex] = LText[0]) and (LTextLength <= ADataLength - LIndex)
      and CompareMem(@AData[LIndex], @LText[0], LTextLength)
    then
    begin
      LMatch.Kind := mkSelfLocating;
      LMatch.Length := LTextLength;
      LMatch.Position := LPosition;

      AResult.Matches := AResult.Matches + [LMatch];
    end;

    Inc(LIndex);
    Inc(LPosition);
    IncrementPositionText(LText, LTextLength);
  end;
end;

procedure TPiFalseStartSearcher.SearchThreadProc;
begin
  try
    Search;
    FinishRun(rsFinished, '');
  except
    on E: Exception do
      FinishRun(rsError, E.Message);
  end;

  TThread.Queue(FThread,
    procedure
    begin
      if Assigned(FOnSearchEnded) then
        FOnSearchEnded(Self);
    end
  );
end;

procedure TPiFalseStartSearcher.ValidateSettings;
begin
  if (FMinMatchLength < MIN_MATCH_LENGTH) or (FMinMatchLength > MAX_PATTERN_LENGTH) then
    raise EArgumentException.CreateFmt('MinMatchLength must be between %d and %d', [MIN_MATCH_LENGTH, MAX_PATTERN_LENGTH]);

  if FListMatchLength < 1 then
    raise EArgumentException.Create('ListMatchLength must be >= 1');

  if FBufferSize < 1024 * 1024 then
    raise EArgumentException.Create('BufferSize must be at least 1 MB');
end;

end.
