local config = require("media_relinker.config")
local logger = require("media_relinker.logger").get_logger("media_relinker.resolve")

local M = {}

M.SKIP_TYPES = {
  Timeline = true,
  ["Compound Clip"] = true,
  ["Fusion Composition"] = true,
  ["Multicam Clip"] = true,
  ["Adjustment Clip"] = true,
  Generator = true,
}

M.SIGNATURE_FIELDS = {
  original_path      = "File Path",
  file_name          = "File Name",
  clip_name          = "Clip Name",
  duration_frames    = "Frames",
  duration_tc        = "Duration",
  resolution         = "Resolution",
  fps                = "FPS",
  start_tc           = "Start TC",
  end_tc             = "End TC",
  start_frame        = "Start Frame",
  end_frame          = "End Frame",
  video_codec        = "Video Codec",
  file_format        = "File Format",
  format             = "Format",
  audio_channels     = "Audio Ch",
  audio_bit_depth    = "Audio Bit Depth",
  audio_sample_rate  = "Audio Sample Rate",
  audio_codec        = "Audio Codec",
  reel_name          = "Reel Name",
  data_level         = "Data Level",
  bit_depth          = "Bit Depth",
  shot               = "Shot",
  scene              = "Scene",
  take               = "Take",
  angle              = "Angle",
  camera_number      = "Camera #",
  camera_serial      = "Camera Serial #",
  camera_model       = "Camera Model",
  camera_make        = "Camera Manufacturer",
  camera_type        = "Camera Type",
  camera_firmware    = "Camera Firmware",
  lens_type          = "Camera Lens Type",
  focal_length       = "Camera Focal Length",
  aperture           = "Camera Aperture",
  iso                = "ISO",
  shutter            = "Shutter",
  white_point        = "White Point",
  color_space        = "Color Space Notes",
  shot_date          = "Shot Date",
  date_recorded      = "Date Recorded",
  date_added         = "Date Added",
  date_modified      = "Date Modified",
  keywords           = "Keywords",
  comments           = "Comments",
  description        = "Description",
  clip_color         = "Clip Color",
  type               = "Type",
  h_flip             = "H-Flip",
  v_flip             = "V-Flip",
  field_dominance    = "Field Dominance",
}

-- Busy-wait sleep; os.execute("ping"/"sleep") flashes a cmd window on Windows.
local function busy_sleep(seconds)
  local deadline = os.clock() + seconds
  while os.clock() < deadline do end
end

local function get_global(name)
  local ok, v = pcall(function() return _G[name] end)
  if ok then return v end
  return nil
end

local function safe_call(fn, ...)
  if type(fn) ~= "function" then return false, "not a function" end
  local ok, res = pcall(fn, ...)
  if not ok then return false, tostring(res) end
  return true, res
end

local function probe_resolve()
  logger.info("Probing for Resolve handle via multiple strategies...")

  local seen = {}
  for _, name in ipairs({"bmd", "fusion", "app", "resolve", "Resolve", "fu", "composition"}) do
    seen[name] = (get_global(name) ~= nil)
  end
  logger.info("Visible globals: bmd=%s fusion=%s app=%s resolve=%s Resolve=%s fu=%s composition=%s",
    tostring(seen.bmd), tostring(seen.fusion), tostring(seen.app), tostring(seen.resolve),
    tostring(seen.Resolve), tostring(seen.fu), tostring(seen.composition))

  -- Order matters: bmd.scriptapp('Resolve') and Resolve() can block ~4s each when
  -- a handle already exists as a global. Try zero-cost global lookups first.
  local strategies = {
    {
      name = "resolve global",
      fn = function()
        local r = get_global("resolve")
        if r ~= nil then return r, nil end
        return nil, "resolve global not defined"
      end,
    },
    {
      name = "Resolve global (already a handle)",
      fn = function()
        local R = get_global("Resolve")
        if R ~= nil and type(R) ~= "function" then return R, nil end
        return nil, "Resolve global missing or callable"
      end,
    },
    {
      name = "bmd.scriptapp('Resolve')",
      fn = function()
        local b = get_global("bmd")
        if not b then return nil, "bmd global not defined" end
        if not b.scriptapp then return nil, "bmd.scriptapp not defined" end
        local ok, r = safe_call(b.scriptapp, "Resolve")
        if not ok then return nil, "scriptapp threw: " .. tostring(r) end
        return r, r == nil and "scriptapp returned nil" or nil
      end,
    },
    {
      name = "Resolve() global function",
      fn = function()
        local R = get_global("Resolve")
        if type(R) == "function" then
          local ok, r = safe_call(R)
          if not ok then return nil, "Resolve() threw: " .. tostring(r) end
          return r, r == nil and "Resolve() returned nil" or nil
        end
        return nil, "Resolve global not a function"
      end,
    },
    {
      name = "app:GetResolve()",
      fn = function()
        local a = get_global("app")
        if not a then return nil, "app global not defined" end
        if not a.GetResolve then return nil, "app.GetResolve not defined" end
        local ok, r = safe_call(a.GetResolve, a)
        if not ok then return nil, "app:GetResolve threw: " .. tostring(r) end
        return r, r == nil and "app:GetResolve returned nil" or nil
      end,
    },
    {
      name = "fusion:GetResolve()",
      fn = function()
        local f = get_global("fusion")
        if not f then return nil, "fusion global not defined" end
        if not f.GetResolve then return nil, "fusion.GetResolve not defined" end
        local ok, r = safe_call(f.GetResolve, f)
        if not ok then return nil, "fusion:GetResolve threw: " .. tostring(r) end
        return r, r == nil and "fusion:GetResolve returned nil" or nil
      end,
    },
    {
      name = "require('fusionscript').scriptapp('Resolve')",
      fn = function()
        local ok, mod = pcall(require, "fusionscript")
        if not ok then return nil, "require failed: " .. tostring(mod) end
        if not mod or not mod.scriptapp then return nil, "fusionscript.scriptapp missing" end
        local ok2, r = safe_call(mod.scriptapp, "Resolve")
        if not ok2 then return nil, "scriptapp threw: " .. tostring(r) end
        return r, r == nil and "scriptapp returned nil" or nil
      end,
    },
  }

  local last_err = "no strategies attempted"
  for attempt = 1, 3 do
    for _, s in ipairs(strategies) do
      local result, why = s.fn()
      if result then
        logger.info("SUCCESS via [%s] on attempt %d/3", s.name, attempt)
        local ok_pm, pm = safe_call(result.GetProjectManager, result)
        if ok_pm and pm then
          logger.info("Handle validated (GetProjectManager OK).")
          return result
        else
          logger.warn("Handle from [%s] failed GetProjectManager check: %s",
            s.name, tostring(pm))
          last_err = "handle invalid from " .. s.name
        end
      else
        logger.debug("  [attempt %d] %s -> %s", attempt, s.name, tostring(why))
        last_err = s.name .. ": " .. tostring(why)
      end
    end
    if attempt < 3 then
      logger.debug("All strategies failed on attempt %d; waiting 1s before retry.", attempt)
      busy_sleep(1.0)
    end
  end
  return nil, last_err
end

function M.connect()
  local resolve, err = probe_resolve()
  if not resolve then
    error("Could not obtain a Resolve handle. Last error: " .. tostring(err) ..
          "\nSee the session log for per-strategy diagnostics.")
  end
  logger.info("Connected to DaVinci Resolve.")
  return resolve
end

function M.get_current_project(resolve)
  local pm = resolve:GetProjectManager()
  if not pm then error("Could not access Project Manager") end
  local project = pm:GetCurrentProject()
  if not project then error("No project currently open") end
  return project
end

local function file_exists(path)
  if not path or path == "" then return false end
  local f = io.open(path, "rb")
  if f then f:close() return true end
  return false
end

function M.get_offline_clips(media_pool)
  local offline = {}
  local seen, kept, type_skipped, online_skipped, dict_fail = 0, 0, 0, 0, 0
  local function walk(folder)
    local clips = folder:GetClipList() or {}
    for _, clip in ipairs(clips) do
      seen = seen + 1
      -- Batched GetClipProperty() returns all props as a dict; some builds return nil,
      -- so fall back to per-field queries rather than dropping the clip.
      local props
      pcall(function() props = clip:GetClipProperty() end)
      local clip_type, path
      if type(props) == "table" then
        clip_type = props["Type"]
        path = props["File Path"]
      else
        dict_fail = dict_fail + 1
        pcall(function() clip_type = clip:GetClipProperty("Type") end)
        pcall(function() path = clip:GetClipProperty("File Path") end)
        props = nil
      end
      if M.SKIP_TYPES[clip_type or ""] then
        type_skipped = type_skipped + 1
      elseif not path or path == "" then
      elseif file_exists(path) then
        online_skipped = online_skipped + 1
      else
        kept = kept + 1
        table.insert(offline, {clip = clip, props = props})
      end
    end
    local subs = folder:GetSubFolderList() or {}
    for _, sub in ipairs(subs) do walk(sub) end
  end
  walk(media_pool:GetRootFolder())
  logger.info("get_offline_clips: seen=%d offline=%d online_skipped=%d type_skipped=%d dict_fallback=%d",
    seen, kept, online_skipped, type_skipped, dict_fail)
  return offline
end

-- Lightweight name+path summary for the UI tree; full signature extraction is deferred to Scan.
function M.extract_summary(entry)
  local props = entry.props or {}
  local path = props["File Path"] or ""
  local name = props["File Name"] or props["Clip Name"]
  if (not name or name == "") and path ~= "" then
    name = path:match("([^/\\]+)$") or path
  end
  return {
    clip = entry.clip,
    props = props,
    original_path = path,
    file_name = name,
  }
end

local function _non_empty(v)
  if v == nil then return nil end
  if type(v) == "string" then
    local s = v:match("^%s*(.-)%s*$")
    if s == "" then return nil end
    return s
  end
  return v
end

function M.extract_signature(clip, cached_props)
  local sig = {}
  if type(cached_props) == "table" and next(cached_props) then
    sig._all_properties = cached_props
  else
    local ok_all, all_props = pcall(function() return clip:GetClipProperty() end)
    if ok_all and type(all_props) == "table" then
      sig._all_properties = all_props
    else
      sig._all_properties = {}
    end
  end

  -- If the batch dict succeeded, use it exclusively: 45 individual GetClipProperty
  -- calls per clip costs ~350ms/clip. Only fall back per-field if the batch was empty.
  local have_batch = next(sig._all_properties) ~= nil
  for key, prop in pairs(M.SIGNATURE_FIELDS) do
    local v = sig._all_properties[prop]
    if not have_batch and not _non_empty(v) then
      local ok, val = pcall(function() return clip:GetClipProperty(prop) end)
      v = ok and val or nil
    end
    sig[key] = _non_empty(v)
  end

  local ok, meta = pcall(function() return clip:GetMetadata() end)
  sig.metadata = (ok and type(meta) == "table") and meta or {}
  local meta_aliases = {
    camera_serial = {"Camera Serial #", "Camera Serial", "SerialNumber"},
    camera_model  = {"Camera Model", "Model"},
    camera_make   = {"Camera Manufacturer", "Make"},
    shot_date     = {"Shot Date", "Date Recorded", "DateTimeOriginal", "CreateDate"},
    reel_name     = {"Reel Name", "Reel"},
    umid          = {"UMID", "UniqueID", "DocumentID"},
  }
  for norm_key, candidates in pairs(meta_aliases) do
    if not sig[norm_key] then
      for _, k in ipairs(candidates) do
        local v = _non_empty(sig.metadata[k])
        if v then sig[norm_key] = v; break end
      end
    end
  end

  sig.clip_object = clip
  return sig
end

-- Relocate a clip by current File Path; used by revert/re-pick since MediaPoolItem
-- handles can't be persisted across plugin runs.
function M.find_clip_by_path(media_pool, target)
  if not media_pool or not target or target == "" then return nil end
  local norm_target = tostring(target):gsub("\\", "/"):lower()
  local found
  local function walk(folder)
    if found then return end
    local clips = folder:GetClipList() or {}
    for _, clip in ipairs(clips) do
      if not M.SKIP_TYPES[clip:GetClipProperty("Type") or ""] then
        local p = clip:GetClipProperty("File Path") or ""
        if p ~= "" and p:gsub("\\", "/"):lower() == norm_target then
          found = clip
          return
        end
      end
    end
    for _, sub in ipairs(folder:GetSubFolderList() or {}) do
      if not found then walk(sub) end
    end
  end
  walk(media_pool:GetRootFolder())
  return found
end

function M.relink(clip, new_path)
  local old_path
  local ok = pcall(function() old_path = clip:GetClipProperty("File Path") end)
  if not file_exists(new_path) then
    local err = "Target file no longer exists"
    logger.warn("Relink FAIL: %s -> %s (%s)", old_path or "?", new_path, err)
    return false, err
  end
  local success, result = pcall(function() return clip:ReplaceClip(new_path) end)
  if not success then
    logger.error("Relink EXC: %s -> %s : %s", old_path or "?", new_path, tostring(result))
    return false, tostring(result)
  end
  if result then
    logger.info("Relink OK: %s -> %s", old_path or "?", new_path)
    return true, nil
  end
  local err = "Resolve API returned false"
  logger.warn("Relink FAIL: %s -> %s (%s)", old_path or "?", new_path, err)
  return false, err
end

return M
