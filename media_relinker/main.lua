local config = require("media_relinker.config")
local logger_mod = require("media_relinker.logger")
local Cache = require("media_relinker.cache")
local ExifTool = require("media_relinker.exiftool")
local Matcher = require("media_relinker.matcher")
local History = require("media_relinker.history")
local RelinkLog = require("media_relinker.relink_log")
local scanner = require("media_relinker.scanner")
local resolve_interface = require("media_relinker.resolve_interface")
local ui = require("media_relinker.ui")

local logger = logger_mod.get_logger("media_relinker.main")

local M = {}

local function format_kv_table(t, skip)
  if type(t) ~= "table" then return nil end
  skip = skip or {}
  local keys = {}
  for k, v in pairs(t) do
    if not skip[k] and v ~= nil and v ~= "" and v ~= "None" and type(v) ~= "table" then
      keys[#keys + 1] = k
    end
  end
  if #keys == 0 then return nil end
  table.sort(keys)
  local parts = {}
  for _, k in ipairs(keys) do parts[#parts + 1] = k .. "=" .. tostring(t[k]) end
  return table.concat(parts, " | ")
end

-- Skip internal/object keys; metadata is formatted separately.
local SIG_SKIP = {clip_object = true, _all_properties = true, metadata = true, id = true}
local function format_signature(sig)
  return format_kv_table(sig, SIG_SKIP) or "(no signature fields)"
end

local function format_metadata(sig)
  return format_kv_table(sig and sig.metadata)
end

local function basename(p)
  if not p or p == "" then return "" end
  return (tostring(p):match("([^/\\]+)$")) or tostring(p)
end

local function log_session_header()
  logger.info(string.rep("#", 70))
  logger.info("# Media Relinker (Lua) v%s", config.VERSION)
  logger.info("# Session log: %s", logger_mod.get_session_log_path())
  logger.info("# Lua: %s", _VERSION)
  logger.info(string.rep("#", 70))
end

-- Lightweight pass: name + path per offline clip. Full signatures are
-- deferred to scan time so showing the window stays near-instant.
local function build_clip_info(offline_entries)
  local out = {}
  logger.info("OFFLINE CLIPS ENUMERATED: %d (signatures deferred to scan)",
    #offline_entries)
  for idx, entry in ipairs(offline_entries) do
    local sum = resolve_interface.extract_summary(entry)
    local path = sum.original_path or ""
    local name = basename(path)
    if (not name or name == "") then name = sum.file_name or ("clip_" .. tostring(idx)) end
    table.insert(out, {
      id = idx,
      clip = entry.clip,
      name = name,
      path = path,
      _cached_props = entry.props,
      signature = nil,
    })
  end
  return out
end

-- Inflate clip_infos with full signatures. Cheap on re-scan because
-- GetClipProperty is already cached in _cached_props.
local function ensure_full_signatures(clip_infos, is_cancelled)
  is_cancelled = is_cancelled or function() return false end
  logger.info(string.rep("=", 70))
  logger.info("Inflating signatures for %d offline clip(s)", #clip_infos)
  logger.info(string.rep("=", 70))
  for idx, info in ipairs(clip_infos) do
    if is_cancelled() then
      logger.info("Signature inflation cancelled at %d/%d", idx, #clip_infos)
      return false
    end
    if not info.signature then
      local sig = resolve_interface.extract_signature(info.clip, info._cached_props)
      sig.id = idx
      logger.info("[%03d] %s", idx, info.name)
      logger.info("      path: %s", info.path ~= "" and info.path or "(no path recorded)")
      logger.info("      sig : %s", format_signature(sig))
      local meta_str = format_metadata(sig)
      if meta_str then logger.info("      meta: %s", meta_str) end
      info.signature = sig
    end
  end
  logger.info(string.rep("=", 70))
  return true
end

local function dedupe_walk(folders, recursive)
  local paths = {}
  local seen = {}
  for _, fld in ipairs(folders) do
    logger.info("Walking folder: %s (recursive=%s)", fld, tostring(recursive))
    local before = #paths
    local ok, files = pcall(scanner.walk_media, fld, recursive, scanner.default_extensions())
    if not ok then
      logger.warn("Walk failed for %s: %s", fld, tostring(files))
    else
      for _, p in ipairs(files) do
        if not seen[p] then
          seen[p] = true
          table.insert(paths, p)
        end
      end
    end
    logger.info("  -> found %d new files in %s", #paths - before, fld)
  end
  return paths
end

function M.scan_and_match(folders, recursive, clip_infos, is_cancelled, on_progress)
  is_cancelled = is_cancelled or function() return false end
  on_progress = on_progress or function() end
  if type(folders) == "string" then folders = {folders} end
  folders = folders or {}
  on_progress("prep", 0, #clip_infos)
  if not ensure_full_signatures(clip_infos, is_cancelled) then return {} end
  if is_cancelled() then return {} end
  on_progress("walk", 0, 0)
  logger.info("Scanning %d folder(s) (recursive=%s)", #folders, tostring(recursive))
  local paths = dedupe_walk(folders, recursive)
  logger.info("Walk complete: %d unique media files", #paths)
  on_progress("walk_done", #paths, #paths)

  if is_cancelled() then logger.info("Scan cancelled after walk"); return {} end

  local cfg = config.load_config()
  local cache = Cache.new()
  local extractor = ExifTool.new({exiftool_path = cfg.exiftool_path, cache = cache})
  if not extractor.available then
    logger.warn("ExifTool unavailable — matches will be weak.")
  end

  on_progress("extract", 0, #paths)
  local t0 = os.clock()
  local files_with_meta = extractor:extract_batch(paths, is_cancelled)
  if is_cancelled() then
    cache:flush()
    logger.info("Scan cancelled after metadata extraction")
    return {}
  end
  local extract_elapsed = os.clock() - t0
  cache:flush()
  local cs = cache:stats()
  local extracted = 0
  for _ in pairs(files_with_meta) do extracted = extracted + 1 end
  logger.info("Metadata ready: %d files in %.2fs (cache: %d hits / %d misses, %d rows on disk)",
    extracted, extract_elapsed, cs.hits, cs.misses, cs.total_rows)

  local matcher = Matcher.new(cfg.weights or {}, {
    auto_match_threshold = cfg.auto_match_threshold or 80,
    strong_threshold = cfg.strong_threshold or 50,
    weak_threshold = cfg.weak_threshold or 20,
  })

  logger.info(string.rep("=", 70))
  logger.info("MATCHING %d clips against disk files", #clip_infos)
  logger.info(string.rep("=", 70))

  local results = {}
  local total_clips = #clip_infos
  on_progress("match", 0, total_clips)
  for idx, info in ipairs(clip_infos) do
    -- Poll per-clip so Close/X feels instant.
    if is_cancelled() then
      logger.info("Matching cancelled at clip %d/%d", idx, total_clips)
      return results
    end
    on_progress("match", idx, total_clips)
    local _clip_t0 = os.clock()
    local cands = matcher:rank_candidates(info.signature, files_with_meta)
    local _clip_elapsed = os.clock() - _clip_t0
    local tm = cands._timings or {}
    logger.info(
      "[%03d] TIMING total=%.3fs (prep=%.4f sweep=%.4f sort=%.4f) files=%d scored=%d rejected=%d",
      info.id, _clip_elapsed,
      tm.prep_clip or 0, tm.score_sweep or 0, tm.sort or 0,
      tm.bucket_files or 0,
      (cands._all_scores and cands._all_scores._scored_count) or 0,
      (cands._all_scores and cands._all_scores._gate_rejected) or 0)
    results[info.id] = cands
    if #cands > 0 then
      logger.info("[%03d] %s -> %d candidate(s) top=%d",
        info.id, info.name, #cands, cands[1].score)
      for rank = 1, math.min(3, #cands) do
        local c = cands[rank]
        logger.debug("      #%d score=%3d %s", rank, c.score, basename(c.path))
        for _, r in ipairs(c.reasons) do logger.debug("            + %s", r) end
      end
    else
      logger.info("[%03d] %s -> NO MATCH (threshold=%d)", info.id, info.name,
        cands._weak_threshold or 0)
      local all = cands._all_scores or {}
      local shown = math.min(3, #all)
      if shown > 0 then
        logger.debug("      Best-below-threshold scores:")
        for rank = 1, shown do
          local c = all[rank]
          logger.debug("      #%d score=%3d %s", rank, c.score, basename(c.path))
          for _, r in ipairs(c.reasons or {}) do
            logger.debug("            * %s", r)
          end
        end
      else
        logger.debug("      (No files available to score against — scan returned empty)")
      end
    end
    cands._all_scores = nil
    -- Periodic full GC: Lua's incremental collector falls behind on big scans.
    if idx % 50 == 0 then collectgarbage("collect") end
  end

  if is_cancelled() then
    logger.info("Scan cancelled after match loop; skipping summary/history")
    return results
  end

  -- Ambiguous only if #1 and #2 tie at or above auto-threshold.
  local auto_t = cfg.auto_match_threshold or 80
  for _, cands in pairs(results) do
    if cands[1] and cands[2]
        and cands[1].score >= auto_t
        and cands[1].score == cands[2].score then
      for _, c in ipairs(cands) do
        if c.score == cands[1].score then c.ambiguous = true end
      end
    end
  end

  local top_owners = {}
  for cid, cands in pairs(results) do
    if cands[1] and cands[1].score >= auto_t then
      top_owners[cands[1].path] = top_owners[cands[1].path] or {}
      table.insert(top_owners[cands[1].path], cid)
    end
  end
  for path, owners in pairs(top_owners) do
    if #owners >= 2 then
      for _, cid in ipairs(owners) do
        for _, c in ipairs(results[cid]) do
          if c.path == path then c["one-source-multiple-clips"] = true end
        end
      end
    end
  end

  local summary = {high = 0, medium = 0, weak = 0, none = 0}
  local strong_t = cfg.strong_threshold or 50
  local weak_t = cfg.weak_threshold or 20
  for _, cands in pairs(results) do
    if not cands[1] then
      summary.none = summary.none + 1
    else
      local top = cands[1].score
      if top >= auto_t then summary.high = summary.high + 1
      elseif top >= strong_t then summary.medium = summary.medium + 1
      elseif top >= weak_t then summary.weak = summary.weak + 1
      else summary.none = summary.none + 1
      end
    end
  end

  local hist_ok, hist_err = pcall(function()
    History.new():record({
      folders_scanned = folders,
      files_scanned = #paths,
      clip_count = #clip_infos,
      clips_offline = #clip_infos,
      relinks_performed = 0,
      match_summary = summary,
    })
  end)
  if not hist_ok then
    logger.warn("History.record failed (non-fatal): %s", tostring(hist_err))
  end

  logger.info("Scan complete.")
  return results
end

function M.perform_relink(selections)
  selections = selections or {}
  local relinked, failed, skipped = 0, 0, 0
  local details = {}
  local journal = RelinkLog.new()
  for _, sel in ipairs(selections) do
    local clip = sel.clip
    local new_path = sel.new_path
    if not clip or not new_path then
      skipped = skipped + 1
      table.insert(details, {success = false, error = "missing clip or path"})
    else
      local old_path = ""
      pcall(function() old_path = clip:GetClipProperty("File Path") or "" end)
      local ok, err = resolve_interface.relink(clip, new_path)
      if ok then
        relinked = relinked + 1
        logger.info("RELINK OK   [score=%s] %s -> %s",
          tostring(sel.score), old_path, new_path)
        pcall(function()
          journal:append({
            clip_name = sel.clip_name or "",
            old_path = old_path,
            new_path = new_path,
            score = sel.score,
            reasons = sel.reasons or {},
            alternatives = sel.alternatives or {},
          })
        end)
      else
        failed = failed + 1
        logger.warn("RELINK FAIL [score=%s] %s -> %s : %s",
          tostring(sel.score), old_path, new_path, tostring(err))
      end
      table.insert(details, {
        old_path = old_path, new_path = new_path,
        score = sel.score, success = ok, error = err,
      })
    end
  end
  logger.info("Relink summary: ok=%d fail=%d skip=%d", relinked, failed, skipped)
  return {relinked = relinked, failed = failed, skipped = skipped, details = details}
end

-- Revert a journal entry: locate clip by current File Path and ReplaceClip
-- back to old_path. Removes the entry on success.
function M.revert_relink(entry_id, media_pool)
  local journal = RelinkLog.new()
  local entry = journal:find(entry_id)
  if not entry then return false, "entry not found" end
  if not media_pool then return false, "media pool unavailable" end
  local clip = resolve_interface.find_clip_by_path(media_pool, entry.new_path)
  if not clip then
    return false, "could not locate clip currently pointing at " .. tostring(entry.new_path)
  end
  local ok, result = pcall(function() return clip:ReplaceClip(entry.old_path) end)
  if not ok or not result then
    return false, "ReplaceClip failed: " .. tostring(result)
  end
  journal:remove(entry_id)
  logger.info("REVERT OK: %s <- %s", entry.old_path, entry.new_path)
  return true, nil
end

-- Re-pick: swap the clip's current target for alt_path (one of
-- entry.alternatives). Updates the journal entry in place.
function M.repick_relink(entry_id, alt_path, media_pool)
  local journal = RelinkLog.new()
  local entry = journal:find(entry_id)
  if not entry then return false, "entry not found" end
  if not media_pool then return false, "media pool unavailable" end
  local clip = resolve_interface.find_clip_by_path(media_pool, entry.new_path)
  if not clip then
    return false, "could not locate clip currently pointing at " .. tostring(entry.new_path)
  end
  local ok, result = pcall(function() return clip:ReplaceClip(alt_path) end)
  if not ok or not result then
    return false, "ReplaceClip failed: " .. tostring(result)
  end
  local chosen
  for _, a in ipairs(entry.alternatives or {}) do
    if a.path == alt_path then chosen = a; break end
  end
  -- Previous target becomes an alternative; old alts minus the pick are kept.
  local new_alts = {}
  table.insert(new_alts, {
    path = entry.new_path, score = entry.score, reasons = entry.reasons,
  })
  for _, a in ipairs(entry.alternatives or {}) do
    if a.path ~= alt_path then table.insert(new_alts, a) end
  end
  journal:update(entry_id, function(e)
    e.new_path = alt_path
    e.score = chosen and chosen.score or nil
    e.reasons = chosen and chosen.reasons or {}
    e.alternatives = new_alts
    e.timestamp = os.date("!%Y-%m-%dT%H:%M:%SZ")
  end)
  logger.info("REPICK OK: %s -> %s", entry.old_path, alt_path)
  return true, nil
end

function M.run()
  log_session_header()
  logger.info("Media Relinker (Lua) starting")

  local ok, resolve = pcall(resolve_interface.connect)
  if not ok then
    logger.error("Resolve connection failed: %s", tostring(resolve))
    ui.show_message("Resolve connection failed", tostring(resolve), "error")
    return 1
  end

  local project, media_pool, offline
  ok, project = pcall(resolve_interface.get_current_project, resolve)
  if not ok then
    ui.show_message("Media Relinker", "No project open: " .. tostring(project), "error")
    return 1
  end
  media_pool = project:GetMediaPool()
  ok, offline = pcall(resolve_interface.get_offline_clips, media_pool)
  if not ok then
    ui.show_message("Media Relinker", "Failed to enumerate clips: " .. tostring(offline), "error")
    return 1
  end

  if #offline == 0 then
    logger.info("No offline clips")
    ui.show_message("Media Relinker", "No offline media found — nothing to do!")
    return 0
  end

  local clip_infos = build_clip_info(offline)
  logger.info("Found %d offline clips", #clip_infos)

  logger.info("Building Fusion UI window...")
  local win = ui.new(clip_infos, {
    on_scan = function(folders, recursive, is_cancelled)
      return M.scan_and_match(folders, recursive, clip_infos, is_cancelled)
    end,
    on_relink = function(selections)
      return M.perform_relink(selections)
    end,
    on_clear_cache = function()
      local c = Cache.new(); c:clear(); c:flush()
    end,
    on_revert = function(entry_id)
      return M.revert_relink(entry_id, media_pool)
    end,
    on_repick = function(entry_id, alt_path)
      return M.repick_relink(entry_id, alt_path, media_pool)
    end,
  }, resolve)
  logger.info("Calling win:show()...")
  win:show()
  logger.info("win:show() returned.")
  return 0
end

return M
