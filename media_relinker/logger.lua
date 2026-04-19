local config = require("media_relinker.config")

local M = {}

local LEVELS = {DEBUG = 1, INFO = 2, WARN = 3, ERROR = 4}

local _session_timestamp = os.date("%Y%m%d_%H%M%S")
local _logs_dir = config.path_join(config.get_config_dir(), "logs")
config.mkdir_p(_logs_dir)
local _session_log = config.path_join(_logs_dir, "session_" .. _session_timestamp .. ".log")

local _file, _open_err = io.open(_session_log, "a")
if not _file then
  io.stderr:write(string.format(
    "logger: cannot open %s: %s\n", _session_log, tostring(_open_err)))
end
local _stderr_min = LEVELS.INFO
local _file_min = LEVELS.DEBUG

local function format_line(level, name, msg)
  local ts = os.date("%Y-%m-%d %H:%M:%S")
  return string.format("%s %-5s %s: %s", ts, level, name, msg)
end

-- Batch INFO/DEBUG writes; force-flush on WARN/ERROR so a crash preserves the last error.
local _buffered_since_flush = 0
local _FLUSH_EVERY = 20

local function emit(level, name, msg)
  local line = format_line(level, name, msg)
  local lvl = LEVELS[level] or LEVELS.INFO
  if _file and lvl >= _file_min then
    _file:write(line .. "\n")
    _buffered_since_flush = _buffered_since_flush + 1
    if lvl >= LEVELS.WARN or _buffered_since_flush >= _FLUSH_EVERY then
      _file:flush()
      _buffered_since_flush = 0
    end
  end
  if lvl >= _stderr_min then
    io.stderr:write(line .. "\n")
  end
end

local function format_args(fmt, ...)
  if select("#", ...) == 0 then return tostring(fmt) end
  local ok, s = pcall(string.format, fmt, ...)
  if ok then return s end
  local parts = {tostring(fmt)}
  for i = 1, select("#", ...) do
    parts[#parts + 1] = tostring(select(i, ...))
  end
  return table.concat(parts, " ")
end

function M.get_logger(name)
  name = name or "media_relinker"
  return {
    debug = function(fmt, ...) emit("DEBUG", name, format_args(fmt, ...)) end,
    info  = function(fmt, ...) emit("INFO",  name, format_args(fmt, ...)) end,
    warn  = function(fmt, ...) emit("WARN",  name, format_args(fmt, ...)) end,
    error = function(fmt, ...) emit("ERROR", name, format_args(fmt, ...)) end,
  }
end

function M.get_session_log_path()
  return _session_log
end

return M
