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

  The files can be read in several ways (TPFSReadMethod), to compare plain
  ReadFile with the IoRing of Pascal.IOUring. All of them find the same matches.
*)

interface

uses
  System.Classes, System.Diagnostics, System.Generics.Collections, System.SyncObjs, System.SysUtils, System.Threading,
  PIRUnit.SequentialReader, PIRUnit.Streams;

const
  // A longer list would only choke the log, the statistics have the counts of all of them
  MAX_LISTED_FALSE_STARTS = 1000;
  MAX_PATTERN_LENGTH = 64;
  // Same as SizeOf(Cardinal), the first digits are compared as one Cardinal
  MIN_MATCH_LENGTH = 4;
  // The parallel engine search: blocks of the file each worker reads, drops the non-digits of and scans
  PARALLEL_BLOCK_SIZE = 8 * 1024 * 1024;
  // The parallel engine search: workers, each with one block in work and the read of its next one in flight
  PARALLEL_WORKER_COUNT = 12;

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
    // Dropping the non-digits, on the search thread while the next buffer is read. Part of ReadSeconds instead with
    // the zero-copy reader, which drops them as it reads.
    CompactSeconds: Double;
    DigitsScanned: Int64;
    ElapsedSeconds: Double;
    LongestMatch: Integer;
    // Reading, in the background while the previous buffer is handled
    ReadSeconds: Double;
    // The scan waiting for the read of the next buffer, and the first read. Near 0: the scan is the limit.
    ReadWaitSeconds: Double;
    // Scanning the buffers and merging the results
    ScanSeconds: Double;
  end;

  TPFSSearchEndedEvent = procedure(const APiSearcher: TPiFalseStartSearcher) of object;

  TPFSSliceResult = record
    Matches: TArray<TPFSMatch>;
    Statistics: TPFSLengthStatistics;
  end;

  // How the digit files are read
  TPFSReadMethod = (
    rmReadFile,               // Windows ReadFile, with the sequential scan hint
    rmFileStream,             // Delphi's TFileStream, the usual way
    rmIORingStream,          // TSequentialReadOnlyFileStream, big reads go straight into the buffer
    rmIORingStreamUnbuffered, // the same, past the file cache
    rmIORingReader,          // TIORingSequentialReader, digits copied straight from its buffers
    rmIORingReaderUnbuffered, // the same, past the file cache
    rmIORingParallel,         // TIORingEngine: PARALLEL_WORKER_COUNT workers read, drop and scan blocks of the file
    rmIORingParallelUnbuffered // the same, past the file cache
  );

  TRunStatus = (rsNone, rsRunning, rsCanceled, rsError, rsFinished);

  // What dropping the non-digits of a piece of a file found. One per thread, merged in file order.
  TPFSCompactState = record
    // Of the first byte of the piece
    FileOffset: Int64;
    // In the piece
    FirstUnexpectedIndex: Integer;
    FirstUnexpectedValue: Byte;
    NonDigitCount: Int64;
    UnexpectedCount: Int64;
    class function Create(const AFileOffset: Int64): TPFSCompactState; static;
  end;

  // One read of TPFSDigitFileReader.Read: where the bytes came from, and whether their non-digits are dropped yet
  TPFSFileRead = record
    ByteCount: Integer;
    // Read and dropped in one go (the zero-copy reader). Then DigitCount is valid, otherwise Compact gives it.
    Compacted: Boolean;
    DigitCount: Integer;
    FileOffset: Int64;
  end;

  { Reads the file and hands out only the digits. With the parallel engine search it only keeps the counts: the
    workers read the file themselves. }
  TPFSDigitFileReader = class(TObject)
  strict private
    FBytesRead: Int64;
    FBytesTotal: Int64;
    FCompactTicks: Int64;
    FFileDone: Boolean;
    FFileName: string;
    FFileOffset: Int64;
    FFileOpen: Boolean;
    FFirstUnexpectedChar: string;
    FHandle: THandle;
    FIORingReader: TIORingSequentialReader;
    FNonDigitCount: Int64;
    FReadMethod: TPFSReadMethod;
    FStream: TStream; // TFileStream or TSequentialReadOnlyFileStream
    FUnexpectedCharCount: Int64;
    function GetBytesRead: Int64;
    function GetCompactTicks: Int64;
    function ReadFromIORingReader(const ABuffer: PByte; const ACapacity: Integer; var ADigitCount: Integer): Integer;
    function ReadRaw(const ABuffer: PByte; const ACapacity: Integer): Integer;
    procedure FileBytesRead(const ACount: Integer);
    procedure OpenFile;
  public
    constructor Create(const AFileName: string; const AReadMethod: TPFSReadMethod);
    destructor Destroy; override;

    // Thread-safe
    procedure AddBytesRead(const ACount: Integer);
    // Thread-safe
    procedure AddCompactTicks(const ATicks: Int64);
    // In file order, from one thread at a time
    procedure AddCompactState(const AState: TPFSCompactState);
    // Also at the end of a canceled or failed run, so no handle keeps the file in the file cache
    procedure CloseCurrentFile;

    { Drops the non-digits of a read in place, in slices on several threads. Returns the number of digits, now at the
      start of ABuffer. Can run on another thread than Read, while Read fills another buffer: so the disk keeps
      reading meanwhile. Not on two threads at once. }
    function Compact(const ABuffer: PByte; const ARead: TPFSFileRead): Integer;
    { Fills ABuffer with the next bytes of the file. Their non-digits are dropped later with Compact, except with the
      zero-copy reader, which copies only the digits out of its own buffers. Returns False when the file is read. }
    function Read(const ABuffer: PByte; const ACapacity: Integer; var ARead: TPFSFileRead): Boolean;
    property BytesRead: Int64 read GetBytesRead;
    property BytesTotal: Int64 read FBytesTotal;
    // TStopwatch ticks spent dropping the non-digits (wall time, also when several threads do it)
    property CompactTicks: Int64 read GetCompactTicks;
    property FirstUnexpectedChar: string read FFirstUnexpectedChar;
    property NonDigitCount: Int64 read FNonDigitCount;
    property UnexpectedCharCount: Int64 read FUnexpectedCharCount;
  end;

  TPiFalseStartSearcher = class(TObject)
  strict private
    FBufferSize: Integer;
    FDigitsScanned: Int64;
    FErrorMessage: string;
    FFileName: string;
    FIntegerDigits: Integer;
    FListedFalseStartCount: Integer;
    FListMatchLength: Integer;
    FLock: TCriticalSection;
    FLongestMatch: Integer;
    FMatches: TList<TPFSMatch>;
    FMinMatchLength: Integer;
    FNextHasData: Boolean;
    FNextRead: TPFSFileRead;
    FNextReadTicks: Int64;
    FOnlyNewLongestMatches: Boolean;
    FOnMatch: TPFSMatchEvent;
    FOnSearchEnded: TPFSSearchEndedEvent;
    FPattern: TBytes;
    FPatternLength: Integer;
    FReader: TPFSDigitFileReader;
    FReadMethod: TPFSReadMethod;
    // TStopwatch ticks, see TPFSProgress
    FReadTicks: Int64;
    FReadWaitTicks: Int64;
    FScanTicks: Int64;
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
    procedure AddTimes(const AReadTicks, AReadWaitTicks, AScanTicks: Int64);
    procedure FinishRun(const AStatus: TRunStatus; const AErrorMessage: string);
    procedure LoadPattern(const AFileName: string);
    procedure MergeSliceResults(const AResults: TArray<TPFSSliceResult>; const AScanCount: Integer);
    procedure QueueMatch(const AMatch: TPFSMatch);
    procedure ScanBuffer(const AData: PByte; const ADataLength, AScanCount: Integer; const ADigitBase: Int64);
    procedure ScanSlice(const AData: PByte; const ADataLength, AFrom, ATo: Integer; const ADigitBase: Int64;
      var AResult: TPFSSliceResult);
    procedure Search;
    procedure SearchParallel;
    procedure SearchSelfLocatingStrings(const AData: PByte; const ADataLength, AFrom, ATo: Integer; const ADigitBase: Int64;
      var AResult: TPFSSliceResult);
    procedure SearchThreadProc;
    procedure ValidateSettings;
  public
    constructor Create(const AOnMatch: TPFSMatchEvent; const AOnSearchEnded: TPFSSearchEndedEvent);
    destructor Destroy; override;

    function GetMatches: TArray<TPFSMatch>;
    function GetStatistics: TPFSLengthStatistics;
    function HasRunEndedStatus: Boolean;
    procedure Cancel;
    // Starts the search in a background thread. Raises on invalid settings or a missing file. A searcher runs only once.
    procedure Execute(const AFileName: string);
    // Read-buffer size in bytes, not with the parallel engine search. Default = 64 MB. Does not affect the matches found.
    property BufferSize: Integer read FBufferSize write FBufferSize;
    property ErrorMessage: string read GetErrorMessage;
    property FileName: string read FFileName;
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
    // How the files are read. Does not affect which matches are found. Default = rmReadFile.
    property ReadMethod: TPFSReadMethod read FReadMethod write FReadMethod;
    // Also look for self-locating strings, the digits at position P spell P (for example "16470" at position 16 470)
    property SearchSelfLocating: Boolean read FSearchSelfLocating write FSearchSelfLocating;
    property Status: TRunStatus read GetStatus;
    property UnexpectedCharCount: Int64 read GetUnexpectedCharCount;
  end;

const
  // For the user interface and the log
  READ_METHOD_NAMES: array[TPFSReadMethod] of string = (
    'ReadFile (Windows API)',
    'TFileStream (Delphi RTL)',
    'IoRing stream (TSequentialReadOnlyFileStream)',
    'IoRing stream, unbuffered',
    'IoRing zero-copy reader (TIORingSequentialReader)',
    'IoRing zero-copy reader, unbuffered',
    'IoRing engine, parallel (TIORingEngine)',
    'IoRing engine, parallel, unbuffered'
  );
  // For the -Read: switch of the console version
  READ_METHOD_SWITCHES: array[TPFSReadMethod] of string = ('ReadFile', 'FileStream', 'IORingStream',
    'IORingStreamUnbuffered', 'IORingReader', 'IORingReaderUnbuffered', 'IORingParallel', 'IORingParallelUnbuffered');

implementation

uses
  Winapi.Windows, System.Generics.Defaults, System.IOUtils, System.Math, PIRUnit.Engine, PIRUnit.IORing;

const
  DEFAULT_BUFFER_SIZE = 64 * 1024 * 1024;
  DEFAULT_LIST_MATCH_LENGTH = 10;
  DIGIT_HIGH_NIBBLES: UInt64 = $3030303030303030;
  HIGH_NIBBLE_MASK: UInt64 = $F0F0F0F0F0F0F0F0;
  LOW_NIBBLE_MASK: UInt64 = $0F0F0F0F0F0F0F0F;
  LOW_NIBBLE_OVERFLOW: UInt64 = $0606060606060606;
  // A run of digits at least this long found 8 at a time is a line of digits, shorter ones mean short groups
  LONG_RUN_BYTES = 32;
  // Shorter runs of digits CompactDigits copies word by word
  MOVE_MIN_BYTES = 64;
  // When the digits come in short groups, CompactDigits goes at first this many bytes one by one before it tries
  // 8 at a time again, then twice as many each time in a row, up to MAX_SHORT_GROUP_BYTES
  MAX_SHORT_GROUP_BYTES = 4096;
  SHORT_GROUP_BYTES = 64;
  SLICE_SIZE = 1024 * 1024;
  // TPFSDigitFileReader.Compact drops the non-digits of slices this big on several threads
  COMPACT_SLICE_SIZE = 4 * 1024 * 1024;
  // The read area of the buffers starts at a page, so unbuffered reads can go straight into it
  PAGE_SIZE = 4096;

type
  TPFSPositionText = array[0..23] of Byte;

  // One block of the parallel engine search, from its read to the merge
  TPFSParallelBlock = record
    // Digit index of its first digit, known once the blocks before it have dropped their non-digits
    Base: Int64;
    // Its first digits, up to the prefix length - 1: the lookahead of the digits before it
    Head: TBytes;
    Result: TPFSSliceResult;
    // The worker scanned its positions 0..ScanCount - 1, those with the whole lookahead in the block
    ScanCount: Integer;
    State: TPFSCompactState;
    // Its digits from ScanCount on, scanned at the seam with the next block
    Tail: TBytes;
    Done: Boolean;
  end;

  { What the workers of the parallel engine search share: the next block to take, the digit index the next block
    starts at, and the finished blocks. The waits end at once when the search is aborted. }
  TPFSParallelState = class(TObject)
  strict private
    FAborted: Boolean;
    FBaseBlock: Integer;
    FBlockCount: Integer;
    FErrorMessage: string;
    FNextBase: Int64;
    FNextBlock: Integer;
    function GetAborted: Boolean;
    function GetErrorMessage: string;
  public
    Blocks: TArray<TPFSParallelBlock>;
    constructor Create(const ABlockCount: Integer);

    // Ends all waits. Keeps the first error message, '' for a cancel.
    procedure Abort(const AErrorMessage: string);
    // The next block to read. False: none left, or aborted.
    function ClaimBlock(var AIndex: Integer): Boolean;
    procedure SetDone(const AIndex: Integer);
    { Waits until the blocks before AIndex have their digit counts, then gives AIndex the digit index it starts at.
      Workers take their bases in block order, so this waits only for blocks other workers are finishing. False:
      aborted. }
    function TakeBase(const AIndex, ADigitCount: Integer; var ABase: Int64): Boolean;
    // False: not done within ATimeoutMilliseconds, or aborted
    function WaitDone(const AIndex: Integer; const ATimeoutMilliseconds: Cardinal): Boolean;
    property Aborted: Boolean read GetAborted;
    property ErrorMessage: string read GetErrorMessage;
  end;

{ TPFSParallelState }

constructor TPFSParallelState.Create(const ABlockCount: Integer);
begin
  inherited Create;

  FBlockCount := ABlockCount;
  SetLength(Blocks, ABlockCount);
end;

procedure TPFSParallelState.Abort(const AErrorMessage: string);
begin
  TMonitor.Enter(Self);
  try
    if not FAborted then
    begin
      FAborted := True;
      FErrorMessage := AErrorMessage;
    end;

    TMonitor.PulseAll(Self);
  finally
    TMonitor.Exit(Self);
  end;
end;

function TPFSParallelState.ClaimBlock(var AIndex: Integer): Boolean;
begin
  AIndex := TInterlocked.Increment(FNextBlock) - 1;

  Result := (AIndex < FBlockCount) and not GetAborted;
end;

function TPFSParallelState.GetAborted: Boolean;
begin
  TMonitor.Enter(Self);
  try
    Result := FAborted;
  finally
    TMonitor.Exit(Self);
  end;
end;

function TPFSParallelState.GetErrorMessage: string;
begin
  TMonitor.Enter(Self);
  try
    Result := FErrorMessage;
  finally
    TMonitor.Exit(Self);
  end;
end;

procedure TPFSParallelState.SetDone(const AIndex: Integer);
begin
  TMonitor.Enter(Self);
  try
    Blocks[AIndex].Done := True;
    TMonitor.PulseAll(Self);
  finally
    TMonitor.Exit(Self);
  end;
end;

function TPFSParallelState.TakeBase(const AIndex, ADigitCount: Integer; var ABase: Int64): Boolean;
begin
  TMonitor.Enter(Self);
  try
    while (FBaseBlock <> AIndex) and not FAborted do
      TMonitor.Wait(Self, INFINITE);

    Result := not FAborted;

    if Result then
    begin
      ABase := FNextBase;
      Inc(FNextBase, ADigitCount);
      Inc(FBaseBlock);
      TMonitor.PulseAll(Self);
    end;
  finally
    TMonitor.Exit(Self);
  end;
end;

function TPFSParallelState.WaitDone(const AIndex: Integer; const ATimeoutMilliseconds: Cardinal): Boolean;
begin
  TMonitor.Enter(Self);
  try
    if not Blocks[AIndex].Done and not FAborted then
      TMonitor.Wait(Self, ATimeoutMilliseconds);

    Result := Blocks[AIndex].Done and not FAborted;
  finally
    TMonitor.Exit(Self);
  end;
end;

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

function IsDigit(const AValue: Byte): Boolean; inline;
begin
  Result := (AValue >= Ord('0')) and (AValue <= Ord('9'));
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

// AIndex = in the piece AState is for
procedure NonDigitFound(const AValue: Byte; const AIndex: Integer; var AState: TPFSCompactState);
begin
  Inc(AState.NonDigitCount);

  // Decimal point and white space are expected, anything else hints at a broken file
  if AValue in [Ord('.'), 9, 10, 13, 32] then
    Exit;

  if AState.UnexpectedCount = 0 then
  begin
    AState.FirstUnexpectedIndex := AIndex;
    AState.FirstUnexpectedValue := AValue;
  end;

  Inc(AState.UnexpectedCount);
end;

{ CompactDigits byte by byte, from AFrom to ATo, writing from AWriteIndex on. Returns the next write index. A routine
  of its own, with pointers in locals: measured (Win64, digits in groups of 5 and 10), the same loop with indexes ran
  1.3-2x slower, inside CompactDigits and here alike. }
function CompactBytes(const ASource, ATarget: PByte; const AFrom, ATo, AWriteIndex: Integer;
  var AState: TPFSCompactState): Integer;
var
  LByte: Byte;
  LEnd: PByte;
  LSource: PByte;
  LTarget: PByte;
begin
  // Pointers in locals: the 5th and later parameters come on the stack (Win64), locals can stay in registers
  LSource := ASource + AFrom;
  LEnd := ASource + ATo;
  LTarget := ATarget + AWriteIndex;

  while LSource < LEnd do
  begin
    LByte := LSource^;

    if (LByte >= Ord('0')) and (LByte <= Ord('9')) then
    begin
      LTarget^ := LByte;
      Inc(LTarget);
    end
    else
      NonDigitFound(LByte, LSource - ASource, AState);

    Inc(LSource);
  end;

  Result := LTarget - ATarget;
end;

{ Copies the digits of ASource to ATarget, which may be ASource itself. Returns the number of digits. What else it
  finds goes to AState, so several threads can each do a piece of a buffer. }
function CompactDigits(const ASource, ATarget: PByte; const ACount: Integer; var AState: TPFSCompactState): Integer;
var
  LIndex: Integer;
  LReadIndex: Integer;
  LRunLength: Integer;
  LRunStart: Integer;
  LSlowBytes: Integer;
  LSlowEnd: Integer;
  LWriteIndex: Integer;
begin
  LReadIndex := 0;
  LSlowBytes := SHORT_GROUP_BYTES;
  LWriteIndex := 0;

  while LReadIndex < ACount do
  begin
    LRunStart := LReadIndex;

    // Fast path, 8 digits at a time: the files are mostly digits, a line usually has tens of them
    while (LReadIndex <= ACount - SizeOf(UInt64)) and IsAllDigits(PUInt64(ASource + LReadIndex)^) do
      Inc(LReadIndex, SizeOf(UInt64));

    LRunLength := LReadIndex - LRunStart;

    // In place the run is already there until the first non-digit. A short run word by word, a call to Move costs more.
    // In place the target is behind the source, so a word is read before anything writes over it.
    if ATarget + LWriteIndex <> ASource + LRunStart then
    begin
      if LRunLength >= MOVE_MIN_BYTES then
        Move(ASource[LRunStart], ATarget[LWriteIndex], LRunLength)
      else
        for LIndex := 0 to LRunLength div SizeOf(UInt64) - 1 do
          PUInt64(ATarget + LWriteIndex + LIndex * SizeOf(UInt64))^ :=
            PUInt64(ASource + LRunStart + LIndex * SizeOf(UInt64))^;
    end;

    Inc(LWriteIndex, LRunLength);

    if LRunLength >= LONG_RUN_BYTES then
    begin
      LSlowBytes := SHORT_GROUP_BYTES;

      // After a long run of digits: the digits up to the non-digits that ended it (a line break, a space) ...
      while (LReadIndex < ACount) and IsDigit(ASource[LReadIndex]) do
      begin
        ATarget[LWriteIndex] := ASource[LReadIndex];
        Inc(LWriteIndex);
        Inc(LReadIndex);
      end;

      // ... and the non-digits, then back to the fast path
      while (LReadIndex < ACount) and not IsDigit(ASource[LReadIndex]) do
      begin
        NonDigitFound(ASource[LReadIndex], LReadIndex, AState);
        Inc(LReadIndex);
      end;
    end
    else
    begin
      { A short run or none, the digits come in short groups (12345 67890 ..., 1234567890 ...): a while byte by
        byte, switching between the fast path and the bytes would only cost there. The while grows each time in a
        row, so a file of short groups is soon read byte by byte nearly all the way. }
      LSlowEnd := Min(LReadIndex + LSlowBytes, ACount);
      LSlowBytes := Min(LSlowBytes * 2, MAX_SHORT_GROUP_BYTES);

      LWriteIndex := CompactBytes(ASource, ATarget, LReadIndex, LSlowEnd, LWriteIndex, AState);
      LReadIndex := LSlowEnd;
    end;
  end;

  Result := LWriteIndex;
end;

{ TPFSCompactState }

class function TPFSCompactState.Create(const AFileOffset: Int64): TPFSCompactState;
begin
  Result := Default(TPFSCompactState);
  Result.FileOffset := AFileOffset;
end;

{ TPFSDigitFileReader }

constructor TPFSDigitFileReader.Create(const AFileName: string; const AReadMethod: TPFSReadMethod);
begin
  inherited Create;

  FFileName := AFileName;
  FFileDone := False;
  FFileOpen := False;
  FHandle := INVALID_HANDLE_VALUE;
  FReadMethod := AReadMethod;
  FStream := nil;

  if not FileExists(FFileName) then
    raise EFileNotFoundException.CreateFmt('File "%s" not found', [FFileName]);

  FBytesTotal := TFile.GetSize(FFileName);
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

function TPFSDigitFileReader.GetCompactTicks: Int64;
begin
  Result := TInterlocked.Read(FCompactTicks);
end;

procedure TPFSDigitFileReader.OpenFile;
begin
  case FReadMethod of
    rmReadFile:
      begin
        FHandle := CreateFile(PChar(FFileName), GENERIC_READ, FILE_SHARE_READ, nil, OPEN_EXISTING,
          FILE_FLAG_SEQUENTIAL_SCAN, 0);

        if FHandle = INVALID_HANDLE_VALUE then
          RaiseLastOSError;
      end;
    rmFileStream:
      FStream := TFileStream.Create(FFileName, fmOpenRead or fmShareDenyWrite);
    rmIORingStream:
      FStream := TSequentialReadOnlyFileStream.Create(FFileName);
    rmIORingStreamUnbuffered:
      FStream := TSequentialReadOnlyFileStream.Create(FFileName, [sroUnbuffered]);
    rmIORingReader:
      FIORingReader.Open(FFileName);
    rmIORingReaderUnbuffered:
      FIORingReader.Open(FFileName, [sroUnbuffered]);
  end;

  FFileOpen := True;
  FFileOffset := 0;
end;

function TPFSDigitFileReader.Read(const ABuffer: PByte; const ACapacity: Integer; var ARead: TPFSFileRead): Boolean;
begin
  ARead := Default(TPFSFileRead);

  if FFileDone then
    Exit(False);

  if not FFileOpen then
    OpenFile;

  ARead.FileOffset := FFileOffset;
  ARead.Compacted := FReadMethod in [rmIORingReader, rmIORingReaderUnbuffered];

  if ARead.Compacted then
    ARead.ByteCount := ReadFromIORingReader(ABuffer, ACapacity, ARead.DigitCount)
  else
    ARead.ByteCount := ReadRaw(ABuffer, ACapacity);

  Result := ARead.ByteCount > 0;

  if not Result then
  begin
    CloseCurrentFile;
    FFileDone := True;
  end;
end;

// Returns the bytes read from the file, 0 at its end. A chunk is taken whole, so it is taken only while it fits in what
// is left of ABuffer: the buffer may be filled up to the reader's buffer size short.
function TPFSDigitFileReader.ReadFromIORingReader(const ABuffer: PByte; const ACapacity: Integer;
  var ADigitCount: Integer): Integer;
var
  LChunk: PByte;
  LChunkLength: NativeInt;
  LStart: Int64;
  LState: TPFSCompactState;
begin
  Result := 0;
  ADigitCount := 0;

  while (ACapacity - ADigitCount >= Integer(FIORingReader.BufferSize))
    and FIORingReader.TryAcquireChunk(LChunk, LChunkLength)
  do
  begin
    LStart := TStopwatch.GetTimeStamp;
    try
      LState := TPFSCompactState.Create(FFileOffset);
      Inc(ADigitCount, CompactDigits(LChunk, ABuffer + ADigitCount, LChunkLength, LState));
    finally
      FIORingReader.ReleaseChunk;
    end;

    TInterlocked.Add(FCompactTicks, TStopwatch.GetTimeStamp - LStart);
    AddCompactState(LState);
    FileBytesRead(LChunkLength);
    Inc(Result, LChunkLength);
  end;
end;

// Reads into ABuffer as is, Compact drops the non-digits later. Returns the bytes read from the file, 0 at its end.
function TPFSDigitFileReader.ReadRaw(const ABuffer: PByte; const ACapacity: Integer): Integer;
var
  LBytesRead: DWORD;
begin
  if FReadMethod = rmReadFile then
  begin
    if not ReadFile(FHandle, ABuffer^, ACapacity, LBytesRead, nil) then
      RaiseLastOSError;

    Result := LBytesRead;
  end
  else
    Result := FStream.Read(ABuffer^, ACapacity);

  FileBytesRead(Result);
end;

procedure TPFSDigitFileReader.AddBytesRead(const ACount: Integer);
begin
  TInterlocked.Add(FBytesRead, Int64(ACount));
end;

procedure TPFSDigitFileReader.AddCompactTicks(const ATicks: Int64);
begin
  TInterlocked.Add(FCompactTicks, ATicks);
end;

procedure TPFSDigitFileReader.AddCompactState(const AState: TPFSCompactState);
begin
  Inc(FNonDigitCount, AState.NonDigitCount);

  if AState.UnexpectedCount = 0 then
    Exit;

  if FUnexpectedCharCount = 0 then
    FFirstUnexpectedChar := Format('$%.2x at byte offset %d of "%s"',
      [AState.FirstUnexpectedValue, AState.FileOffset + AState.FirstUnexpectedIndex, FFileName]);

  Inc(FUnexpectedCharCount, AState.UnexpectedCount);
end;

{ Each slice moves its digits to its own start, then the gaps between the slices are closed in order; a file of digits
  only has none. One thread could not keep up with the IoRing reads. }
function TPFSDigitFileReader.Compact(const ABuffer: PByte; const ARead: TPFSFileRead): Integer;
var
  LCounts: TArray<Integer>;
  LSliceCount: Integer;
  LSliceStart: Integer;
  LStart: Int64;
  LStates: TArray<TPFSCompactState>;
begin
  if ARead.Compacted then
    Exit(ARead.DigitCount);

  LStart := TStopwatch.GetTimeStamp;
  LSliceCount := (ARead.ByteCount + COMPACT_SLICE_SIZE - 1) div COMPACT_SLICE_SIZE;
  SetLength(LCounts, LSliceCount);
  SetLength(LStates, LSliceCount);

  TParallel.for(0, LSliceCount - 1,
    procedure(AIndex: Integer)
    var
      LFrom: Integer;
    begin
      LFrom := AIndex * COMPACT_SLICE_SIZE;
      LStates[AIndex] := TPFSCompactState.Create(ARead.FileOffset + LFrom);
      LCounts[AIndex] := CompactDigits(ABuffer + LFrom, ABuffer + LFrom, Min(COMPACT_SLICE_SIZE, ARead.ByteCount - LFrom),
        LStates[AIndex]);
    end
  );

  Result := 0;

  for var LIndex := 0 to LSliceCount - 1 do
  begin
    LSliceStart := LIndex * COMPACT_SLICE_SIZE;

    if Result <> LSliceStart then
      Move(ABuffer[LSliceStart], ABuffer[Result], LCounts[LIndex]);

    Inc(Result, LCounts[LIndex]);
    AddCompactState(LStates[LIndex]);
  end;

  TInterlocked.Add(FCompactTicks, TStopwatch.GetTimeStamp - LStart);
end;

procedure TPFSDigitFileReader.CloseCurrentFile;
begin
  if FHandle <> INVALID_HANDLE_VALUE then
  begin
    CloseHandle(FHandle);
    FHandle := INVALID_HANDLE_VALUE;
  end;

  FreeAndNil(FStream);
  FIORingReader.Close;
  FFileOpen := False;
end;

procedure TPFSDigitFileReader.FileBytesRead(const ACount: Integer);
begin
  Inc(FFileOffset, ACount);
  TInterlocked.Add(FBytesRead, Int64(ACount));
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
  FReadMethod := rmReadFile;
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
    Result.CompactSeconds := FReader.CompactTicks / TStopwatch.Frequency;
  end;

  FLock.Acquire;
  try
    Result.DigitsScanned := FDigitsScanned;
    Result.ElapsedSeconds := FStopwatch.Elapsed.TotalSeconds;
    Result.LongestMatch := FLongestMatch;
    Result.ReadSeconds := FReadTicks / TStopwatch.Frequency;
    Result.ReadWaitSeconds := FReadWaitTicks / TStopwatch.Frequency;
    Result.ScanSeconds := FScanTicks / TStopwatch.Frequency;
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
    var
      LStart: Int64;
    begin
      LStart := TStopwatch.GetTimeStamp;
      FNextHasData := FReader.Read(ABuffer, FBufferSize, FNextRead);
      FNextReadTicks := TStopwatch.GetTimeStamp - LStart;
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

procedure TPiFalseStartSearcher.AddTimes(const AReadTicks, AReadWaitTicks, AScanTicks: Int64);
begin
  FLock.Acquire;
  try
    Inc(FReadTicks, AReadTicks);
    Inc(FReadWaitTicks, AReadWaitTicks);
    Inc(FScanTicks, AScanTicks);
  finally
    FLock.Release;
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

procedure TPiFalseStartSearcher.Execute(const AFileName: string);
begin
  if GetStatus <> rsNone then
    raise EInvalidOpException.Create('A searcher runs only once, create a new one for the next run');

  if AFileName.IsEmpty then
    raise EArgumentException.Create('No file to search');

  ValidateSettings;

  FFileName := AFileName;
  FReader := TPFSDigitFileReader.Create(FFileName, FReadMethod);
  LoadPattern(FFileName);

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
  LEnd: Int64;
  LHasData: Boolean;
  LRead: TPFSFileRead;
  LReadStarts: array[0..1] of Integer;
  LReadTask: ITask;
  LReserve: Integer;
  LScanCount: Integer;
  LStart: Int64;
  LUsed: Integer;
  LWaitStart: Int64;
begin
  // Room in front of the read area for the digits carried over from the previous buffer
  LReserve := FPatternLength - 1;

  // The read area starts at a page, so unbuffered reads can go straight into it
  for LCurrent := Low(LBuffers) to High(LBuffers) do
  begin
    SetLength(LBuffers[LCurrent], LReserve + PAGE_SIZE + FBufferSize);
    LReadStarts[LCurrent] := LReserve + Integer((PAGE_SIZE - NativeUInt(@LBuffers[LCurrent][LReserve]) mod PAGE_SIZE)
      mod PAGE_SIZE);
  end;

  LCurrent := 0;
  LCarryLength := 0;
  LDigitBase := 0;
  LStart := TStopwatch.GetTimeStamp;
  LHasData := FReader.Read(@LBuffers[LCurrent][LReadStarts[LCurrent]], FBufferSize, LRead);
  LEnd := TStopwatch.GetTimeStamp;
  // Nothing to scan meanwhile, the first read is all waiting
  AddTimes(LEnd - LStart, LEnd - LStart, 0);

  while LHasData and not HasRunEndedStatus do
  begin
    // The next read goes on while this buffer's non-digits are dropped and it is scanned
    LReadTask := StartReadTask(@LBuffers[1 - LCurrent][LReadStarts[1 - LCurrent]]);
    try
      LDigitCount := FReader.Compact(@LBuffers[LCurrent][LReadStarts[LCurrent]], LRead);
      LData := @LBuffers[LCurrent][LReadStarts[LCurrent] - LCarryLength];
      LUsed := LCarryLength + LDigitCount;

      LStart := TStopwatch.GetTimeStamp;
      // Only positions with a full prefix length of lookahead, the rest are carried to the next buffer
      LScanCount := Max(0, LUsed - FPatternLength + 1);
      ScanBuffer(LData, LUsed, LScanCount, LDigitBase);
    finally
      LWaitStart := TStopwatch.GetTimeStamp;
      WaitForTask(LReadTask);
    end;

    AddTimes(FNextReadTicks, TStopwatch.GetTimeStamp - LWaitStart, LWaitStart - LStart);

    LCarryLength := LUsed - LScanCount;

    if LCarryLength > 0 then
      Move(LData[LScanCount], LBuffers[1 - LCurrent][LReadStarts[1 - LCurrent] - LCarryLength], LCarryLength);

    Inc(LDigitBase, LScanCount);
    LCurrent := 1 - LCurrent;
    LHasData := FNextHasData;
    LRead := FNextRead;
  end;

  // The last digits of the file
  if not HasRunEndedStatus then
    ScanBuffer(@LBuffers[LCurrent][LReadStarts[LCurrent] - LCarryLength], LCarryLength, LCarryLength, LDigitBase);
end;

{ The parallel engine search. PARALLEL_WORKER_COUNT workers each take the next block of the file, read it through the
  engine (the read of their next block is already in flight meanwhile), drop its non-digits and scan the positions that
  have their whole lookahead in the block. A block's digit index is known once the blocks before it have dropped their
  non-digits, so the workers take it in block order (TPFSParallelState.TakeBase). This thread merges the results in
  file order and scans the seams: the last digits of a block with the first digits of the next. Every byte of the file
  is read once, no reads overlap. }
procedure TPiFalseStartSearcher.SearchParallel;
var
  LBlock: TPFSParallelBlock;
  LBlockCount: Integer;
  LCarry: TBytes;
  LCarryBase: Int64;
  LEngine: TIORingEngine;
  LFile: THandle;
  LKeptLength: Integer;
  LSeam: TBytes;
  LSeamScan: Integer;
  LState: TPFSParallelState;
  LTasks: TArray<ITask>;
  LWorker: TProc;
begin
  LBlockCount := Integer((FReader.BytesTotal + PARALLEL_BLOCK_SIZE - 1) div PARALLEL_BLOCK_SIZE);
  LFile := TIORingPlatform.OpenFileForRead(FFileName, FReadMethod = rmIORingParallelUnbuffered, False);
  try
    // Each worker keeps two reads at most: its block's and the next one's
    LEngine := TIORingEngine.Create(4 * PARALLEL_WORKER_COUNT);
    try
      LState := TPFSParallelState.Create(LBlockCount);
      try
        LWorker :=
          procedure
          var
            LBase: Int64;
            LBuffers: array[0..1] of PByte;
            LCompletion: TIORingCompletion;
            LDigitCount: Integer;
            LHandles: array[0..1] of TIORingRequestHandle;
            LHasNext: Boolean;
            LIndex: Integer;
            LInFlight: array[0..1] of Boolean;
            LNextIndex: Integer;
            LSide: Integer;
            LStart: Int64;
            LTarget: ^TPFSParallelBlock;
            LWaitTicks: Int64;
          begin
            LBuffers[0] := TIORingPlatform.AllocPages(PARALLEL_BLOCK_SIZE);
            LBuffers[1] := TIORingPlatform.AllocPages(PARALLEL_BLOCK_SIZE);
            LInFlight[0] := False;
            LInFlight[1] := False;
            try
              try
                LSide := 0;
                LHasNext := LState.ClaimBlock(LIndex);

                if LHasNext then
                begin
                  LHandles[LSide] := LEngine.ReadAsync(LFile, LBuffers[LSide]^, PARALLEL_BLOCK_SIZE,
                    UInt64(LIndex) * PARALLEL_BLOCK_SIZE);
                  LInFlight[LSide] := True;
                end;

                while LHasNext do
                begin
                  // The next block's read goes on while this one is handled
                  LHasNext := LState.ClaimBlock(LNextIndex);

                  if LHasNext then
                  begin
                    LHandles[1 - LSide] := LEngine.ReadAsync(LFile, LBuffers[1 - LSide]^, PARALLEL_BLOCK_SIZE,
                      UInt64(LNextIndex) * PARALLEL_BLOCK_SIZE);
                    LInFlight[1 - LSide] := True;
                  end;

                  LStart := TStopwatch.GetTimeStamp;
                  LInFlight[LSide] := False;
                  LEngine.Wait(LHandles[LSide], LCompletion);
                  LCompletion.RaiseIfFailed('Read');
                  LWaitTicks := TStopwatch.GetTimeStamp - LStart;
                  FReader.AddBytesRead(Integer(LCompletion.BytesTransferred));

                  // The array is not resized while the workers run, so the pointer stays valid
                  LTarget := @LState.Blocks[LIndex];

                  LStart := TStopwatch.GetTimeStamp;
                  LTarget^.State := TPFSCompactState.Create(Int64(LIndex) * PARALLEL_BLOCK_SIZE);
                  LDigitCount := CompactDigits(LBuffers[LSide], LBuffers[LSide], Integer(LCompletion.BytesTransferred),
                    LTarget^.State);
                  FReader.AddCompactTicks(TStopwatch.GetTimeStamp - LStart);

                  if not LState.TakeBase(LIndex, LDigitCount, LBase) then
                    Break;

                  LStart := TStopwatch.GetTimeStamp;
                  LTarget^.Base := LBase;
                  LTarget^.ScanCount := Max(0, LDigitCount - FPatternLength + 1);
                  ScanSlice(LBuffers[LSide], LDigitCount, 0, LTarget^.ScanCount, LBase, LTarget^.Result);

                  SetLength(LTarget^.Head, Min(LDigitCount, FPatternLength - 1));
                  SetLength(LTarget^.Tail, LDigitCount - LTarget^.ScanCount);

                  if Length(LTarget^.Head) > 0 then
                    Move(LBuffers[LSide]^, LTarget^.Head[0], Length(LTarget^.Head));

                  if Length(LTarget^.Tail) > 0 then
                    Move(LBuffers[LSide][LTarget^.ScanCount], LTarget^.Tail[0], Length(LTarget^.Tail));

                  AddTimes(0, LWaitTicks, TStopwatch.GetTimeStamp - LStart);
                  LState.SetDone(LIndex);

                  LIndex := LNextIndex;
                  LSide := 1 - LSide;
                end;
              except
                on E: Exception do
                  LState.Abort(E.Message);
              end;
            finally
              // The buffers may go only after their reads
              for LSide := 0 to 1 do
                if LInFlight[LSide] then
                  LEngine.Wait(LHandles[LSide], LCompletion);

              TIORingPlatform.FreePages(LBuffers[0], PARALLEL_BLOCK_SIZE);
              TIORingPlatform.FreePages(LBuffers[1], PARALLEL_BLOCK_SIZE);
            end;
          end;

        SetLength(LTasks, PARALLEL_WORKER_COUNT);

        for var LIndex := 0 to High(LTasks) do
          LTasks[LIndex] := TTask.Run(LWorker);

        try
          LCarry := nil;
          LCarryBase := 0;

          // The blocks in file order: first the seam of the digits before the block, then the block's own positions
          for var LIndex := 0 to LBlockCount - 1 do
          begin
            while not LState.WaitDone(LIndex, 100) do
            begin
              if HasRunEndedStatus then
                LState.Abort('');

              if LState.Aborted then
                Break;
            end;

            if LState.Aborted then
              Break;

            LBlock := LState.Blocks[LIndex];
            LState.Blocks[LIndex] := Default(TPFSParallelBlock);

            LSeam := LCarry + LBlock.Head;
            // The carried digits that now have their whole lookahead, all of them unless the block is tiny
            LSeamScan := Min(Length(LCarry), Max(0, Length(LSeam) - FPatternLength + 1));

            if LSeamScan > 0 then
              ScanBuffer(@LSeam[0], Length(LSeam), LSeamScan, LCarryBase);

            MergeSliceResults([LBlock.Result], LBlock.ScanCount);
            FReader.AddCompactState(LBlock.State);

            LKeptLength := Length(LCarry) - LSeamScan;
            LCarry := Copy(LCarry, LSeamScan, LKeptLength) + LBlock.Tail;
            LCarryBase := LBlock.Base + LBlock.ScanCount - LKeptLength;
          end;

          // The last digits of the file. Not aborted here also means all blocks are merged.
          if not LState.Aborted and not HasRunEndedStatus and (Length(LCarry) > 0) then
            ScanBuffer(@LCarry[0], Length(LCarry), Length(LCarry), LCarryBase);
        finally
          // Ends the workers' waits when the merge stopped early. After a normal end nothing waits anymore. Keeps a
          // worker's error message.
          LState.Abort('');

          for var LTask in LTasks do
            LTask.Wait;
        end;

        if not LState.ErrorMessage.IsEmpty then
          raise EInOutError.Create(LState.ErrorMessage);
      finally
        LState.Free;
      end;
    finally
      LEngine.Free;
    end;
  finally
    CloseHandle(LFile);
  end;
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
    try
      if FReadMethod in [rmIORingParallel, rmIORingParallelUnbuffered] then
        SearchParallel
      else
        Search;
    finally
      // A canceled or failed run stops in the middle of a file, it must not stay open (and in the file cache)
      FReader.CloseCurrentFile;
    end;

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

  if not (FReadMethod in [rmReadFile, rmFileStream]) and not IORingAvailable then
    raise ENotSupportedException.Create('IoRing is not available, it needs Windows 11 24H2 or newer');
end;

end.
