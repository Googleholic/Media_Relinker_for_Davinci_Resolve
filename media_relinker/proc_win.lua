-- Windows flash-free subprocess launcher via LuaJIT FFI + CreateProcess with
-- CREATE_NO_WINDOW. Returns nil if FFI is unavailable so callers fall back to
-- io.popen. Returned object mimics io.popen: :read("*l"/"*a"), :close().

local ok_ffi, ffi = pcall(require, "ffi")
if not ok_ffi then return nil end

local M = {}

-- pcall keeps re-require safe: redefining cdef types throws.
local CDEF = [[
typedef void* HANDLE;
typedef unsigned long DWORD;
typedef int BOOL;
typedef const char* LPCSTR;
typedef char* LPSTR;
typedef void* LPVOID;
typedef unsigned int UINT;

typedef struct {
  DWORD nLength;
  LPVOID lpSecurityDescriptor;
  BOOL bInheritHandle;
} SECURITY_ATTRIBUTES;

typedef struct {
  DWORD cb;
  LPSTR lpReserved;
  LPSTR lpDesktop;
  LPSTR lpTitle;
  DWORD dwX;
  DWORD dwY;
  DWORD dwXSize;
  DWORD dwYSize;
  DWORD dwXCountChars;
  DWORD dwYCountChars;
  DWORD dwFillAttribute;
  DWORD dwFlags;
  unsigned short wShowWindow;
  unsigned short cbReserved2;
  void* lpReserved2;
  HANDLE hStdInput;
  HANDLE hStdOutput;
  HANDLE hStdError;
} STARTUPINFOA;

typedef struct {
  HANDLE hProcess;
  HANDLE hThread;
  DWORD dwProcessId;
  DWORD dwThreadId;
} PROCESS_INFORMATION;

BOOL CreatePipe(HANDLE* hReadPipe, HANDLE* hWritePipe, SECURITY_ATTRIBUTES* lpPipeAttributes, DWORD nSize);
BOOL SetHandleInformation(HANDLE hObject, DWORD dwMask, DWORD dwFlags);
BOOL CreateProcessA(LPCSTR lpApplicationName, LPSTR lpCommandLine, SECURITY_ATTRIBUTES* lpProcessAttributes, SECURITY_ATTRIBUTES* lpThreadAttributes, BOOL bInheritHandles, DWORD dwCreationFlags, LPVOID lpEnvironment, LPCSTR lpCurrentDirectory, STARTUPINFOA* lpStartupInfo, PROCESS_INFORMATION* lpProcessInformation);
BOOL CloseHandle(HANDLE hObject);
BOOL ReadFile(HANDLE hFile, LPVOID lpBuffer, DWORD nNumberOfBytesToRead, DWORD* lpNumberOfBytesRead, LPVOID lpOverlapped);
BOOL TerminateProcess(HANDLE hProcess, UINT uExitCode);
DWORD WaitForSingleObject(HANDLE hHandle, DWORD dwMilliseconds);
DWORD GetLastError();
]]
pcall(function() ffi.cdef(CDEF) end)

local k32_ok, k32 = pcall(ffi.load, "kernel32")
if not k32_ok then return nil end

local STARTF_USESTDHANDLES = 0x00000100
local CREATE_NO_WINDOW     = 0x08000000
local HANDLE_FLAG_INHERIT  = 0x00000001

local Proc = {}
Proc.__index = Proc

function Proc:_fill_buffer()
  local chunk = ffi.new("char[4096]")
  local nread = ffi.new("DWORD[1]")
  if k32.ReadFile(self._h_read, chunk, 4096, nread, nil) == 0 or nread[0] == 0 then
    return false
  end
  self._buf = self._buf .. ffi.string(chunk, nread[0])
  return true
end

function Proc:read(fmt)
  fmt = fmt or "*l"
  if fmt == "*l" or fmt == "l" then
    while true do
      local nl = self._buf:find("\n", 1, true)
      if nl then
        local line = self._buf:sub(1, nl - 1):gsub("\r$", "")
        self._buf = self._buf:sub(nl + 1)
        return line
      end
      if not self:_fill_buffer() then
        if self._buf ~= "" then
          local line = self._buf:gsub("\r$", "")
          self._buf = ""
          return line
        end
        return nil
      end
    end
  elseif fmt == "*a" or fmt == "a" then
    while self:_fill_buffer() do end
    local out = self._buf
    self._buf = ""
    return out
  end
  return nil
end

function Proc:close()
  if self._closed then return true end
  self._closed = true
  pcall(function() k32.CloseHandle(self._h_read) end)
  -- 50ms grace for clean exit (exiftool daemon exits on -stay_open False).
  local wait_ok = pcall(function()
    return k32.WaitForSingleObject(self._h_proc, 50)
  end)
  if not wait_ok then
    pcall(function() k32.TerminateProcess(self._h_proc, 0) end)
  end
  pcall(function() k32.CloseHandle(self._h_proc) end)
  pcall(function() k32.CloseHandle(self._h_thread) end)
  return true
end

function M.popen_read(cmd)
  local sa = ffi.new("SECURITY_ATTRIBUTES")
  sa.nLength = ffi.sizeof("SECURITY_ATTRIBUTES")
  sa.bInheritHandle = 1
  sa.lpSecurityDescriptor = nil

  local h_read  = ffi.new("HANDLE[1]")
  local h_write = ffi.new("HANDLE[1]")
  if k32.CreatePipe(h_read, h_write, sa, 0) == 0 then
    return nil, "CreatePipe failed: " .. tostring(k32.GetLastError())
  end
  -- Child only inherits the write end.
  k32.SetHandleInformation(h_read[0], HANDLE_FLAG_INHERIT, 0)

  local si = ffi.new("STARTUPINFOA")
  si.cb = ffi.sizeof("STARTUPINFOA")
  si.dwFlags = STARTF_USESTDHANDLES
  si.hStdOutput = h_write[0]
  si.hStdError  = h_write[0]
  si.hStdInput  = nil

  local pi = ffi.new("PROCESS_INFORMATION")

  -- CreateProcessA mutates the command-line buffer; Lua strings are immutable.
  local cmd_buf = ffi.new("char[?]", #cmd + 1)
  ffi.copy(cmd_buf, cmd)

  local rc = k32.CreateProcessA(nil, cmd_buf, nil, nil, 1,
    CREATE_NO_WINDOW, nil, nil, si, pi)
  if rc == 0 then
    local err = tostring(k32.GetLastError())
    k32.CloseHandle(h_read[0])
    k32.CloseHandle(h_write[0])
    return nil, "CreateProcessA failed: " .. err
  end

  -- Must close parent's write end so ReadFile sees EOF when child exits.
  k32.CloseHandle(h_write[0])

  local self = setmetatable({
    _h_read   = h_read[0],
    _h_proc   = pi.hProcess,
    _h_thread = pi.hThread,
    _buf      = "",
    _closed   = false,
  }, Proc)
  return self
end

return M
