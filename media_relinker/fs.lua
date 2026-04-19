-- Filesystem abstraction. Prefers LuaFileSystem, then Fusion's bmd helpers,
-- then shell-free io.open probes.

local M = {}

local logger
local function get_logger()
  if not logger then
    logger = require("media_relinker.logger").get_logger("media_relinker.fs")
  end
  return logger
end

local lfs_ok, lfs = pcall(require, "lfs")
M.has_lfs = lfs_ok and type(lfs) == "table"

-- Probe Fusion's bmd global for filesystem helpers. Logged once so we
-- can see which APIs are available on the user's Resolve build.
local _bmd_probed = false
local _bmd_fs = nil
local function probe_bmd_fs()
  if _bmd_probed then return _bmd_fs end
  _bmd_probed = true
  local ok, bmd_mod = pcall(function() return _G.bmd end)
  if not ok or type(bmd_mod) ~= "table" then return nil end
  local interesting = {}
  local candidates = {
    "fileexists", "direxists", "isdir", "isfile",
    "readdir", "listdir", "listfiles", "dir", "ls",
    "parseFilename", "mapPath", "createdir", "mkdir",
    "getfilesize", "getfileinfo", "getfilemtime",
  }
  for _, key in ipairs(candidates) do
    if bmd_mod[key] ~= nil then
      interesting[key] = type(bmd_mod[key])
    end
  end
  local all_keys = {}
  for k, v in pairs(bmd_mod) do
    table.insert(all_keys, k .. "(" .. type(v) .. ")")
  end
  table.sort(all_keys)
  local log = require("media_relinker.logger").get_logger("media_relinker.fs")
  log.info("bmd filesystem helpers detected: %s",
    (next(interesting) and "" or "(none)"))
  for k, t in pairs(interesting) do log.info("  bmd.%s = %s", k, t) end
  log.info("All bmd.* keys (%d): %s", #all_keys, table.concat(all_keys, ", "))
  _bmd_fs = bmd_mod
  return _bmd_fs
end
M.probe_bmd_fs = probe_bmd_fs

local function is_windows()
  return package.config:sub(1, 1) == "\\"
end
M.is_windows = is_windows

local function normalize(path)
  if not path then return path end
  if is_windows() then return (path:gsub("/", "\\")) end
  return path
end

local function io_file_openable(path)
  local f = io.open(path, "rb")
  if f then f:close() return true end
  return false
end

-- Shell-free directory existence test.
-- Windows: `<dir>\NUL` opens iff the directory exists.
-- POSIX: `<dir>/.` resolves to the directory itself.
local function dir_exists_shellfree(path)
  if is_windows() then
    local probe = path:gsub("/", "\\")
    if probe:sub(-1) ~= "\\" then probe = probe .. "\\" end
    return io_file_openable(probe .. "NUL")
  end
  return io_file_openable(path .. "/.")
end

function M.exists(path)
  if not path or path == "" then return false end
  if M.has_lfs then
    return lfs.attributes(path, "mode") ~= nil
  end
  if io_file_openable(path) then return true end
  return dir_exists_shellfree(path)
end

function M.is_dir(path)
  if not path or path == "" then return false end
  if M.has_lfs then
    return lfs.attributes(path, "mode") == "directory"
  end
  local b = probe_bmd_fs()
  if b and type(b.direxists) == "function" then
    local ok, r = pcall(b.direxists, path)
    if ok then return r == true end
  end
  return dir_exists_shellfree(path)
end

function M.is_file(path)
  if not path or path == "" then return false end
  if M.has_lfs then
    return lfs.attributes(path, "mode") == "file"
  end
  return io_file_openable(path)
end

function M.size(path)
  if not path then return nil end
  if M.has_lfs then
    local a = lfs.attributes(path)
    return a and a.size or nil
  end
  local f = io.open(path, "rb")
  if not f then return nil end
  local ok, sz = pcall(function() return f:seek("end") end)
  f:close()
  if ok then return sz end
  return nil
end

function M.mtime(path)
  if not path then return nil end
  if M.has_lfs then
    local a = lfs.attributes(path)
    return a and a.modification or nil
  end
  return nil
end

-- Returns entry names (not full paths), excluding "." and "..". bmd.readdir
-- can return either { { Name=..., IsDir=... }, ... } or an array of strings
-- depending on Fusion build; both shapes handled below.
function M.listdir(path)
  if not path or path == "" then return nil, "empty path" end
  if M.has_lfs then
    local ok, iter, state = pcall(lfs.dir, path)
    if not ok then return nil, tostring(iter) end
    local out = {}
    for name in iter, state do
      if name ~= "." and name ~= ".." then
        table.insert(out, name)
      end
    end
    return out
  end
  local bmd_mod = probe_bmd_fs()
  if bmd_mod and type(bmd_mod.readdir) == "function" then
    -- bmd.readdir needs a glob pattern like "E:\\path\\*".
    local sep = is_windows() and "\\" or "/"
    local glob = path
    if glob:sub(-1) ~= sep and glob:sub(-1) ~= "/" and glob:sub(-1) ~= "\\" then
      glob = glob .. sep
    end
    glob = glob .. "*"
    local ok, entries = pcall(bmd_mod.readdir, glob)
    if ok and type(entries) == "table" then
      local out = {}
      for i, e in ipairs(entries) do
        local name
        if type(e) == "table" then
          name = e.Name or e.name or e[1]
        else
          name = tostring(e)
        end
        if name and name ~= "" and name ~= "." and name ~= ".." then
          -- Some builds return full paths; strip to basename.
          name = name:match("([^/\\]+)$") or name
          table.insert(out, name)
        end
      end
      return out
    end
    return nil, "bmd.readdir failed: " .. tostring(entries)
  end
  return nil, "no filesystem backend available (no lfs, no bmd.readdir)"
end

function M.has_native_listdir()
  if M.has_lfs then return true end
  local b = probe_bmd_fs()
  return b ~= nil and type(b.readdir) == "function"
end

function M.mkdir_p(path)
  if not path or path == "" then return false end
  if M.exists(path) then return true end
  if M.has_lfs then
    local parent = path:match("^(.*)[/\\][^/\\]+$")
    if parent and parent ~= "" and parent ~= path then M.mkdir_p(parent) end
    local ok, err = lfs.mkdir(path)
    if ok or M.exists(path) then return true end
    get_logger().warn("lfs.mkdir failed for %s: %s", path, tostring(err))
    return false
  end
  -- Shell fallback for cold install without lfs.
  local cmd
  if is_windows() then
    cmd = 'mkdir "' .. normalize(path) .. '" >nul 2>&1'
  else
    cmd = 'mkdir -p "' .. path .. '" >/dev/null 2>&1'
  end
  os.execute(cmd)
  return M.exists(path)
end

return M
