local config = require("media_relinker.config")
local json = require("media_relinker.json")
local logger = require("media_relinker.logger").get_logger("media_relinker.exiftool")

-- Flash-free subprocess launcher on Windows; requires LuaJIT FFI.
local proc_win
if config.is_windows() then
  local ok, mod = pcall(require, "media_relinker.proc_win")
  if ok then proc_win = mod end
end

local M = {}
M.__index = M

M.FIELDS = {
  "Duration", "MediaDuration", "TrackDuration",
  "ImageSize", "ImageWidth", "ImageHeight",
  "VideoFrameRate", "FrameRate",
  "FileType", "MIMEType",
  "DateTimeOriginal", "CreateDate", "ModifyDate",
  "FileModifyDate", "FileCreateDate",
  "TimeCode", "StartTimecode", "MediaCreateDate",
  "CameraModelName", "Make", "Model",
  "SerialNumber", "InternalSerialNumber",
  "ReelName", "CameraID", "CameraSerialNumber",
  "FileSize",
  "CompressorID", "VideoCodec",
  "AudioChannels", "AudioSampleRate", "AudioBitsPerSample", "AudioFormat",
  "Title", "ClipName",
  "UniqueID", "DocumentID", "MediaUID",
}

-- Files per exiftool call. Argfile mode bypasses CMD's 8191-char limit;
-- we still chunk for progress updates and bounded failure blast radius.
M.BATCH_SIZE = 500
M.MAX_CMD_CHARS = 7000

local function count_keys(t)
  local n = 0
  for _ in pairs(t) do n = n + 1 end
  return n
end

local function path_is_file(path)
  if not path or path == "" then return false end
  local f = io.open(path, "rb")
  if f then f:close() return true end
  return false
end

-- Shell-free PATH walk — avoids spawning cmd for `where`/`command -v`.
local function which(name)
  local exe = name
  if config.is_windows() and not exe:lower():match("%.exe$") then
    exe = exe .. ".exe"
  end
  local path_env = os.getenv("PATH") or ""
  local sep = config.is_windows() and ";" or ":"
  local pathsep = config.is_windows() and "\\" or "/"
  for dir in (path_env .. sep):gmatch("([^" .. sep .. "]*)" .. sep) do
    if dir ~= "" then
      local candidate = dir .. pathsep .. exe
      if path_is_file(candidate) then return candidate end
    end
  end
  return nil
end

function M.locate(explicit)
  if explicit and path_is_file(explicit) then return explicit end
  local cfg = config.load_config()
  if cfg.exiftool_path and path_is_file(cfg.exiftool_path) then
    return cfg.exiftool_path
  end
  local w = which("exiftool")
  if w then return w end
  local candidates = {}
  local env_home = os.getenv("MEDIA_RELINKER_HOME")
  if env_home and env_home ~= "" then
    if config.is_windows() then
      table.insert(candidates, config.path_join(env_home, "bin", "windows", "exiftool.exe"))
    else
      table.insert(candidates, config.path_join(env_home, "bin", "exiftool"))
    end
    table.insert(candidates, config.path_join(env_home, "plugin", "bin", "windows", "exiftool.exe"))
  end
  local plugin_home = config.path_join(config.get_config_dir(), "plugin")
  if config.is_windows() then
    table.insert(candidates, config.path_join(plugin_home, "bin", "windows", "exiftool.exe"))
  else
    table.insert(candidates, config.path_join(plugin_home, "bin", "exiftool"))
  end
  for _, c in ipairs(candidates) do
    if path_is_file(c) then return c end
  end
  return nil
end

function M.new(opts)
  opts = opts or {}
  local self = setmetatable({}, M)
  self.cache = opts.cache
  self.exe = M.locate(opts.exiftool_path)
  self.available = self.exe ~= nil
  if not self.available then
    logger.warn("ExifTool not found; metadata extraction disabled.")
  else
    logger.debug("ExifTool located: %s", self.exe)
  end
  return self
end

local function shell_escape(s)
  if config.is_windows() then
    return '"' .. tostring(s):gsub('"', '\\"') .. '"'
  end
  return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
end

local function duration_to_seconds(v)
  if v == nil then return nil end
  if type(v) == "number" then return v end
  if type(v) ~= "string" then return nil end
  local s = v:match("^%s*(.-)%s*$")
  if s == "" then return nil end
  if s:find(":") then
    local total = 0
    for part in s:gmatch("[^:]+") do
      local n = tonumber(part)
      if not n then return nil end
      total = total * 60 + n
    end
    return total
  end
  local token = s:match("^(%S+)")
  return tonumber(token)
end

local function normalise(rec)
  local function g(...)
    for i = 1, select("#", ...) do
      local k = select(i, ...)
      local v = rec[k]
      if v ~= nil and v ~= "" then return v end
    end
    return nil
  end

  local width = g("ImageWidth")
  local height = g("ImageHeight")
  local image_size = g("ImageSize")
  if (not width or not height) and type(image_size) == "string" then
    local w, h = image_size:match("^(%d+)[x×](%d+)$")
    if w then
      width = width or tonumber(w)
      height = height or tonumber(h)
    end
  end

  -- Matcher needs MediaDuration (video-track mdhd timescale) specifically;
  -- the movie-level Duration rounds to a coarser timescale and drifts 1-3 frames.
  local media_dur_raw = g("MediaDuration", "TrackDuration", "Duration")
  local duration_raw = g("Duration", "MediaDuration", "TrackDuration")
  local duration_seconds = duration_to_seconds(duration_raw)

  local file_size = g("FileSize")
  if type(file_size) == "string" then
    file_size = tonumber(file_size) or file_size
  end

  return {
    source_file = rec.SourceFile,
    FileType = g("FileType"),
    MIMEType = g("MIMEType"),
    FileSize = file_size,
    Duration = duration_raw,
    MediaDuration = g("MediaDuration"),
    TrackDuration = g("TrackDuration"),
    DurationSeconds = duration_seconds,
    _media_dur = media_dur_raw,
    ImageWidth = width,
    ImageHeight = height,
    ImageSize = (type(image_size) == "string") and image_size or
      ((width and height) and (tostring(width) .. "x" .. tostring(height)) or nil),
    VideoFrameRate = g("VideoFrameRate", "FrameRate"),
    FrameRate = g("FrameRate", "VideoFrameRate"),
    TimeCode = g("TimeCode"),
    StartTimecode = g("StartTimecode"),
    DateTimeOriginal = g("DateTimeOriginal"),
    CreateDate = g("CreateDate"),
    ModifyDate = g("ModifyDate"),
    MediaCreateDate = g("MediaCreateDate"),
    Make = g("Make"),
    Model = g("CameraModelName", "Model"),
    CameraModelName = g("CameraModelName"),
    SerialNumber = g("SerialNumber", "InternalSerialNumber", "CameraSerialNumber"),
    InternalSerialNumber = g("InternalSerialNumber"),
    CameraSerialNumber = g("CameraSerialNumber"),
    ReelName = g("ReelName"),
    CameraID = g("CameraID"),
    VideoCodec = g("VideoCodec", "CompressorID"),
    CompressorID = g("CompressorID"),
    AudioChannels = g("AudioChannels"),
    AudioSampleRate = g("AudioSampleRate"),
    AudioBitsPerSample = g("AudioBitsPerSample"),
    AudioFormat = g("AudioFormat"),
    FileModifyDate = g("FileModifyDate"),
    FileCreateDate = g("FileCreateDate"),
    Title = g("Title"),
    ClipName = g("ClipName"),
    UniqueID = g("UniqueID", "MediaUID", "DocumentID"),
    MediaUID = g("MediaUID"),
    DocumentID = g("DocumentID"),
  }
end
M._normalise = normalise

local function abspath(p)
  if config.is_windows() then
    return (p:gsub("/", "\\"))
  end
  return p
end

-- Emit paths to a temp argfile (-@) rather than passing on the command line:
-- bypasses Windows CMD's 8191-char ceiling and avoids quoting gotchas.
local function write_argfile(paths, exe)
  local tmpdir = os.getenv("TEMP") or os.getenv("TMP") or os.getenv("TMPDIR") or "."
  local name = string.format("mr_exif_%d_%d.args", os.time(), math.random(100000, 999999))
  local path = tmpdir .. (config.is_windows() and "\\" or "/") .. name
  local f, err = io.open(path, "w")
  if not f then
    return nil, "open argfile failed: " .. tostring(err)
  end
  -- exiftool -@ reads one arg per line, no quoting/escaping.
  for _, p in ipairs(paths) do
    f:write(p, "\n")
  end
  f:close()
  return path
end

-- Daemon mode: one persistent exiftool process handles every batch. Commands
-- are appended to an argfile; after each `-execute` exiftool prints `{ready}`
-- which we use as a batch terminator.
function M:_daemon_start()
  if self.daemon then return self.daemon end
  local tmpdir = os.getenv("TEMP") or os.getenv("TMP") or "."
  local sep = config.is_windows() and "\\" or "/"
  local stamp = string.format("%d_%d", os.time(), math.random(100000, 999999))
  local cmdfile = tmpdir .. sep .. "mr_exif_daemon_" .. stamp .. ".args"
  local seed = io.open(cmdfile, "w"); if seed then seed:close() end
  -- Via CreateProcess stderr is already merged by STARTUPINFO, so no `2>&1`
  -- or outer cmd.exe quoting is needed (and would break the launch).
  local proc, how
  if proc_win then
    local cmd = string.format('%s -stay_open True -@ %s',
      shell_escape(self.exe), shell_escape(cmdfile))
    logger.info("Starting exiftool daemon (flash-free via CreateProcess)")
    proc, how = proc_win.popen_read(cmd)
    if not proc then
      logger.debug("Hidden spawn failed: %s — falling through to io.popen", tostring(how))
    end
  end
  if not proc then
    local cmd = string.format('%s -stay_open True -@ %s 2>&1',
      shell_escape(self.exe), shell_escape(cmdfile))
    if config.is_windows() then cmd = '"' .. cmd .. '"' end
    logger.info("Starting exiftool daemon via io.popen")
    proc = io.popen(cmd, "r")
  end
  if not proc then
    logger.warn("Daemon spawn failed — falling back to per-batch processes")
    return nil
  end
  self.daemon = {proc = proc, cmdfile = cmdfile}
  return self.daemon
end

function M:_daemon_stop()
  local d = self.daemon
  if not d then return end
  logger.info("Stopping exiftool daemon")
  local f = io.open(d.cmdfile, "a")
  if f then
    f:write("-stay_open\nFalse\n-execute\n")
    f:close()
  end
  pcall(function() d.proc:read("*a") end)
  pcall(function() d.proc:close() end)
  pcall(os.remove, d.cmdfile)
  self.daemon = nil
end

function M:_daemon_run(batch)
  local d = self:_daemon_start()
  if not d then return nil end
  local f = io.open(d.cmdfile, "a")
  if not f then return nil end
  f:write("-j\n-n\n-charset\nfilename=UTF8\n")
  for _, field in ipairs(M.FIELDS) do f:write("-", field, "\n") end
  for _, p in ipairs(batch) do f:write(p, "\n") end
  f:write("-execute\n")
  f:close()
  local buf = {}
  while true do
    local line = d.proc:read("*l")
    if not line then
      logger.warn("Daemon pipe closed unexpectedly")
      self.daemon = nil
      return nil
    end
    if line == "{ready}" or line:match("^{ready}%s*$") then break end
    buf[#buf + 1] = line
  end
  return table.concat(buf, "\n")
end

function M:_run(batch)
  if not self.available then return {} end
  if #batch == 0 then return {} end

  local out = self:_daemon_run(batch)
  local argfile
  if not out then
    logger.warn("Daemon run returned nil — using fallback one-shot spawn")
    local af, err = write_argfile(batch, self.exe)
    if not af then
      logger.warn("Argfile write failed: %s — falling back to inline args", tostring(err))
      return self:_run_inline(batch)
    end
    argfile = af
    local args = {shell_escape(self.exe), "-j", "-n", "-charset", "filename=UTF8"}
    for _, field in ipairs(M.FIELDS) do table.insert(args, "-" .. field) end
    table.insert(args, "-@")
    table.insert(args, shell_escape(argfile))
    local proc
    if proc_win then
      proc = proc_win.popen_read(table.concat(args, " "))
    end
    if not proc then
      local cmd = table.concat(args, " ") .. " 2>&1"
      if config.is_windows() then cmd = '"' .. cmd .. '"' end
      proc = io.popen(cmd, "r")
    end
    if not proc then return {} end
    out = proc:read("*a") or ""
    proc:close()
  end
  if argfile then pcall(os.remove, argfile) end
  logger.debug("exiftool raw output: %d bytes", #out)
  if #out > 0 and #out < 1000 then
    logger.debug("exiftool raw output content: %s", out)
  elseif #out >= 1000 then
    logger.debug("exiftool raw output (first 500 chars): %s", out:sub(1, 500))
  end
  if out == "" then
    logger.warn("ExifTool returned empty output for batch of %d files", #batch)
    return {}
  end
  -- Strip all control chars 0-31 before JSON decode: exiftool occasionally
  -- emits raw control bytes inside string values (binary EXIF fields), which
  -- strict parsers reject even for whitespace controls inside string literals.
  local cleaned, n_stripped = out:gsub("[%z\1-\31]", " ")
  if n_stripped > 0 then
    logger.debug("Sanitised %d control char(s) from exiftool output", n_stripped)
  end
  -- Trim to the outermost [..] — exiftool writes informational lines like
  -- "9 image files read" to stderr which our 2>&1 merges ahead of the JSON.
  local json_start = cleaned:find("[", 1, true)
  local json_end = cleaned:find("]", 1, true)
  if json_end then
    local search_from = json_end
    while true do
      local next_bracket = cleaned:find("]", search_from + 1, true)
      if not next_bracket then break end
      json_end = next_bracket
      search_from = next_bracket
    end
  end
  if json_start and json_end and json_end > json_start then
    cleaned = cleaned:sub(json_start, json_end)
  end
  -- Try the whole array first; if that fails, fall through to per-record
  -- parsing so a single malformed record (unescaped backslash in UserComment
  -- etc.) costs one file, not the whole batch.
  local results = {}
  local ok_all, records = pcall(json.decode, cleaned)
  if ok_all and type(records) == "table" then
    for _, rec in ipairs(records) do
      if rec.SourceFile then
        results[abspath(rec.SourceFile)] = normalise(rec)
      end
    end
    return results
  end

  logger.warn("Batch JSON parse failed (%s) — per-record fallback",
    tostring(records))
  local chunks = {}
  local depth, in_str, esc, start = 0, false, false, nil
  for i = 1, #cleaned do
    local c = cleaned:sub(i, i)
    if esc then
      esc = false
    elseif in_str then
      if c == "\\" then esc = true
      elseif c == '"' then in_str = false end
    else
      if c == '"' then in_str = true
      elseif c == "{" then
        if depth == 0 then start = i end
        depth = depth + 1
      elseif c == "}" then
        depth = depth - 1
        if depth == 0 and start then
          chunks[#chunks + 1] = cleaned:sub(start, i)
          start = nil
        end
      end
    end
  end
  local ok_count, fail_count = 0, 0
  for _, chunk in ipairs(chunks) do
    local ok, rec = pcall(json.decode, chunk)
    if ok and type(rec) == "table" and rec.SourceFile then
      results[abspath(rec.SourceFile)] = normalise(rec)
      ok_count = ok_count + 1
    else
      fail_count = fail_count + 1
      if fail_count <= 3 then
        logger.debug("Record parse failed (%s): %s",
          tostring(rec), chunk:sub(1, 200))
      end
    end
  end
  logger.info("Per-record parse: %d ok, %d failed (of %d chunks)",
    ok_count, fail_count, #chunks)
  return results
end

-- Inline-args fallback used if temp-argfile creation fails (e.g. read-only TEMP).
function M:_run_inline(batch)
  if not self.available then return {} end
  local args = {shell_escape(self.exe), "-j", "-n", "-charset", "filename=UTF8"}
  for _, field in ipairs(M.FIELDS) do
    table.insert(args, "-" .. field)
  end
  for _, p in ipairs(batch) do
    table.insert(args, shell_escape(p))
  end
  local proc
  if proc_win then
    proc = proc_win.popen_read(table.concat(args, " "))
  end
  if not proc then
    local cmd = table.concat(args, " ") .. " 2>&1"
    if config.is_windows() then cmd = '"' .. cmd .. '"' end
    proc = io.popen(cmd, "r")
  end
  if not proc then return {} end
  local out = proc:read("*a") or ""
  proc:close()
  if out == "" then return {} end
  local cleaned = out:gsub("[%z\1-\31]", " ")
  local a, b = cleaned:find("[", 1, true), cleaned:find("]", 1, true)
  if b then
    local s = b
    while true do local nb = cleaned:find("]", s + 1, true); if not nb then break end; b = nb; s = nb end
  end
  if a and b and b > a then cleaned = cleaned:sub(a, b) end
  local ok, records = pcall(json.decode, cleaned)
  if not ok or type(records) ~= "table" then return {} end
  local results = {}
  for _, rec in ipairs(records) do
    if rec.SourceFile then results[abspath(rec.SourceFile)] = normalise(rec) end
  end
  return results
end

M.parse_output = function(stdout_text)
  local ok, records = pcall(json.decode, stdout_text)
  if not ok or type(records) ~= "table" then return {} end
  local out = {}
  for _, rec in ipairs(records) do
    if rec.SourceFile then
      out[rec.SourceFile] = normalise(rec)
    end
  end
  return out
end

local function summarise_meta(m)
  if type(m) ~= "table" then return "(nil)" end
  local fields = {"Duration", "MediaDuration", "TrackDuration", "TimeCode",
    "StartTimecode", "ImageSize", "VideoFrameRate", "FileType",
    "CreateDate", "DateTimeOriginal", "FileModifyDate", "FileCreateDate",
    "CameraModelName", "Make", "Model", "ReelName", "UniqueID",
    "MediaUID", "FileSize"}
  local parts = {}
  for _, k in ipairs(fields) do
    local v = m[k]
    if v ~= nil and v ~= "" then table.insert(parts, k .. "=" .. tostring(v)) end
  end
  return #parts > 0 and table.concat(parts, " | ") or "(no metadata)"
end

function M:extract_batch(paths, is_cancelled)
  is_cancelled = is_cancelled or function() return false end
  local results = {}
  local uncached = {}
  local missing = 0
  for _, raw in ipairs(paths or {}) do
    local ap = abspath(raw)
    if path_is_file(ap) then
      if self.cache then
        local cached = self.cache:get(ap)
        if cached then
          results[ap] = cached
        else
          table.insert(uncached, ap)
        end
      else
        table.insert(uncached, ap)
      end
    else
      missing = missing + 1
      logger.warn("File not readable (skipped): %s", raw)
    end
  end

  logger.info("extract_batch: %d path(s) input | %d cached | %d to extract | %d missing",
    #(paths or {}), count_keys(results), #uncached, missing)

  local total_cached = count_keys(results)
  local i = 1
  while i <= #uncached do
    if is_cancelled() then
      logger.info("Extraction cancelled before batch starting at %d/%d",
        i, #uncached)
      self:_daemon_stop()
      return results
    end
    local chunk = {}
    for j = i, math.min(i + M.BATCH_SIZE - 1, #uncached) do
      table.insert(chunk, uncached[j])
    end
    logger.info("Invoking exiftool on batch %d..%d (%d files)",
      i, i + #chunk - 1, #chunk)
    local batch_results = self:_run(chunk)
    local extracted = 0
    for ap, meta in pairs(batch_results) do
      results[ap] = meta
      if self.cache then self.cache:put(ap, meta) end
      extracted = extracted + 1
    end
    logger.info("  Batch returned metadata for %d/%d files", extracted, #chunk)
    i = i + #chunk
  end
  logger.info("extract_batch complete: %d cached hits + %d fresh extractions = %d total",
    total_cached, #uncached, count_keys(results))
  self:_daemon_stop()

  logger.info("=== SCANNED FILE METADATA (%d files) ===", count_keys(results))
  local idx = 0
  for ap, meta in pairs(results) do
    idx = idx + 1
    local name = ap:match("([^/\\]+)$") or ap
    logger.info("[scan %03d] %s", idx, name)
    logger.info("          path: %s", ap)
    logger.info("          meta: %s", summarise_meta(meta))
  end
  logger.info("=== END SCANNED FILE METADATA ===")
  return results
end

function M:extract_one(path)
  local ap = abspath(path)
  local r = self:extract_batch({ap})
  return r[ap]
end

return M
