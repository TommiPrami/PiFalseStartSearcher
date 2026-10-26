unit PFSUnit.FileCache;

(*
  Removing files from the Windows file cache
  ==========================================

  Opening a file without buffering (FILE_FLAG_NO_BUFFERING) makes Windows write
  out and drop the cached data of that file, so the next read comes from the
  disk. This needs no administrator rights, and other files stay in the cache.

  It does not work while another program has the file open with caching, or
  mapped into memory: then the data stays in the cache.
*)

interface

// Removes the files from the Windows file cache, so the next read of them comes from the disk
procedure PurgeFileCache(const AFileNames: TArray<string>);

implementation

uses
  Winapi.Windows, System.SysUtils;

procedure PurgeFileCache(const AFileNames: TArray<string>);
var
  LHandle: THandle;
begin
  for var LFileName in AFileNames do
  begin
    LHandle := CreateFile(PChar(LFileName), GENERIC_READ, FILE_SHARE_READ or FILE_SHARE_WRITE or FILE_SHARE_DELETE,
      nil, OPEN_EXISTING, FILE_FLAG_NO_BUFFERING, 0);

    if LHandle = INVALID_HANDLE_VALUE then
      raise EOSError.CreateFmt('Cannot open "%s" to remove it from the file cache: %s',
        [LFileName, SysErrorMessage(GetLastError)]);

    // Opening it was enough, Windows dropped the cached data
    CloseHandle(LHandle);
  end;
end;

end.
