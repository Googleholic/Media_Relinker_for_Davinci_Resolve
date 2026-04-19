local json = require("media_relinker.json")

local M = {}

M.VERSION = "1.0.0"

M.DEFAULT_CONFIG = {
  auto_match_threshold = 70,
  strong_threshold = 50,
  weak_threshold = 20,
  extensions = {
    video = {".mov", ".mp4", ".mxf", ".avi", ".mkv", ".braw", ".r3d", ".m4v"},
    image = {".jpg", ".jpeg", ".png", ".tiff", ".tif", ".dpx", ".exr"},
    audio = {".wav", ".aif", ".aiff", ".mp3", ".flac", ".aac"},
  },
  weights = {
    umid_exact = 100,
    tc_duration_exact = 80,
    start_tc_exact = 40,
    duration_frame_exact = 30,
    duration_within_1_frame = 20,
    duration_within_3_frames = 10,
    duration_within_10_frames = 5,
    duration_within_30_frames = 2,
    duration_gate_frames = 30,
    date_duration_combo = 15,
    resolution_exact = 15,
    codec_exact = 10,
    size_exact = 15,
    size_within_1pct = 3,
    reel_name_exact = 35,
    camera_serial_date = 80,
    datetime_combo = 70,
    time_within_5s_same_day = 30,
    time_within_1m_same_day = 25,
    date_same_day = 15,
    datetime_within_1h = 8,
    filename_exact = 10,
    filename_fuzzy = 3,
    audio_ch_exact = 5,
    fps_exact = 5,
  },
  cache_expiry_days = 90,
  exiftool_path = nil,
  show_filters = {high = true, medium = true, low = true, none = true},
}

local function is_windows()
  local sep = package.config:sub(1, 1)
  return sep == "\\"
end
M.is_windows = is_windows

function M.home_dir()
  if is_windows() then
    local up = os.getenv("USERPROFILE")
    if up and up ~= "" then return up end
    local drive = os.getenv("HOMEDRIVE") or ""
    local path = os.getenv("HOMEPATH") or ""
    if drive ~= "" or path ~= "" then return drive .. path end
  end
  local h = os.getenv("HOME")
  if h and h ~= "" then return h end
  return "."
end

function M.path_join(...)
  local sep = is_windows() and "\\" or "/"
  local parts = {...}
  local out
  for i, p in ipairs(parts) do
    if p == nil or p == "" then
    elseif i == 1 or out == nil then
      out = p
    else
      local last = out:sub(-1)
      if last == "/" or last == "\\" then
        out = out .. p
      else
        out = out .. sep .. p
      end
    end
  end
  return out or ""
end

function M.mkdir_p(path)
  require("media_relinker.fs").mkdir_p(path)
end

function M.path_exists(path)
  return require("media_relinker.fs").exists(path)
end

function M.is_dir(path)
  return require("media_relinker.fs").is_dir(path)
end

function M.get_config_dir()
  local env = os.getenv("MEDIA_RELINKER_HOME")
  local base = (env and env ~= "") and env or M.path_join(M.home_dir(), ".media_relinker")
  M.mkdir_p(base)
  return base
end

local function deep_copy(t)
  if type(t) ~= "table" then return t end
  local out = {}
  for k, v in pairs(t) do out[k] = deep_copy(v) end
  return out
end
M.deep_copy = deep_copy

local function is_array(t)
  if type(t) ~= "table" then return false end
  local n = 0
  for k in pairs(t) do
    if type(k) ~= "number" then return false end
    n = n + 1
  end
  return n > 0 or next(t) == nil
end

local function deep_merge(defaults, user)
  local out = {}
  for k, v in pairs(defaults) do
    if user[k] ~= nil then
      local uv = user[k]
      if type(v) == "table" and type(uv) == "table" and not is_array(v) then
        out[k] = deep_merge(v, uv)
      else
        out[k] = uv
      end
    else
      out[k] = deep_copy(v)
    end
  end
  for k, v in pairs(user) do
    if out[k] == nil then out[k] = v end
  end
  return out
end

function M.load_config()
  local path = M.path_join(M.get_config_dir(), "config.json")
  local f = io.open(path, "r")
  if not f then
    M.save_config(M.DEFAULT_CONFIG)
    return deep_copy(M.DEFAULT_CONFIG)
  end
  local content = f:read("*a")
  f:close()
  local ok, user = pcall(json.decode, content)
  if not ok or type(user) ~= "table" then
    return deep_copy(M.DEFAULT_CONFIG)
  end
  return deep_merge(M.DEFAULT_CONFIG, user)
end

function M.save_config(cfg)
  local path = M.path_join(M.get_config_dir(), "config.json")
  local f = io.open(path, "w")
  if not f then return false end
  f:write(json.encode(cfg))
  f:close()
  return true
end

return M
