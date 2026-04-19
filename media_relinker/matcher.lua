local config = require("media_relinker.config")
local levenshtein = require("media_relinker.levenshtein")
local timecode = require("media_relinker.timecode")

local M = {}
M.__index = M

local function norm_str(v)
  if v == nil then return nil end
  local s = tostring(v):match("^%s*(.-)%s*$")
  if s == "" then return nil end
  return s
end

local function norm_lower(v)
  local s = norm_str(v)
  if s then return s:lower() end
  return nil
end

local function to_float(v)
  if v == nil then return nil end
  if type(v) == "number" then return v end
  if type(v) == "string" then
    return tonumber((v:gsub(",", "")):match("^%s*(.-)%s*$"))
  end
  return nil
end

local function to_int(v)
  local f = to_float(v)
  if f then return math.floor(f) end
  return nil
end

local function parse_resolution(v)
  if not v then return nil end
  local s = tostring(v):lower():gsub("%s", "")
  local w, h = s:match("^(%d+)[x×](%d+)$")
  if w then return tonumber(w), tonumber(h) end
  return nil
end

local MONTHS = {Jan=1,Feb=2,Mar=3,Apr=4,May=5,Jun=6,Jul=7,Aug=8,Sep=9,Oct=10,Nov=11,Dec=12}

local function _mktime(Y, Mo, D, h, mi, se)
  local ok, t = pcall(os.time, {
    year = tonumber(Y), month = tonumber(Mo), day = tonumber(D),
    hour = tonumber(h) or 0, min = tonumber(mi) or 0, sec = tonumber(se) or 0,
  })
  if ok then return t end
  return nil
end

local function parse_datetime(v)
  if not v then return nil end
  local s = tostring(v):match("^%s*(.-)%s*$")
  if s == "" then return nil end
  s = s:gsub("Z$", ""):gsub("[+-]%d%d:?%d%d$", "")
  local Y, Mo, D, h, mi, se = s:match("^(%d%d%d%d)[:%-](%d%d)[:%-](%d%d)[T ](%d%d):(%d%d):(%d%d)")
  if Y then return _mktime(Y, Mo, D, h, mi, se) end
  local Mon, Dd, hh, mm, ss, Yy = s:match("^%a+%s+(%a+)%s+(%d+)%s+(%d+):(%d+):(%d+)%s+(%d%d%d%d)$")
  if Mon and MONTHS[Mon] then
    return _mktime(Yy, MONTHS[Mon], Dd, hh, mm, ss)
  end
  Mon, Dd, Yy, hh, mm, ss = s:match("^%a+%s+(%a+)%s+(%d+)%s+(%d%d%d%d)%s+(%d+):(%d+):(%d+)$")
  if Mon and MONTHS[Mon] then
    return _mktime(Yy, MONTHS[Mon], Dd, hh, mm, ss)
  end
  return nil
end

local function basename(path)
  if not path then return nil end
  local b = path:match("([^/\\]+)$")
  return b
end

local function extract_filename_timestamp(name)
  if not name then return nil end
  local s = name
  local Y, Mo, D, h, mi, se = s:match("(%d%d%d%d)[-_:](%d%d)[-_:](%d%d)[ _T-](%d%d)[-_:](%d%d)[-_:](%d%d)")
  if not Y then
    Y, Mo, D, h, mi, se = s:match("(%d%d%d%d)(%d%d)(%d%d)[ _T-]?(%d%d)(%d%d)(%d%d)")
  end
  if not Y then return nil end
  local ok, t = pcall(os.time, {
    year = tonumber(Y), month = tonumber(Mo), day = tonumber(D),
    hour = tonumber(h), min = tonumber(mi), sec = tonumber(se),
  })
  if ok then return t end
  return nil
end

local function stem(name)
  if not name then return nil end
  local s = name:match("^(.*)%.[^%.]+$")
  return s or name
end

local function file_size(path)
  local f = io.open(path, "rb")
  if not f then return nil end
  local ok, sz = pcall(function() return f:seek("end") end)
  f:close()
  if ok then return sz end
  return nil
end

-- YYYYMMDD integer: cheap same-day compare without allocating per pair.
local function ymd_of(epoch)
  if not epoch then return nil end
  local d = os.date("*t", epoch)
  return d.year * 10000 + d.month * 100 + d.day
end

function M.new(weights, thresholds)
  local self = setmetatable({}, M)
  self.w = weights or {}
  local t = thresholds or {}
  self.weak_threshold = tonumber(t.weak_threshold) or 20
  self.strong_threshold = tonumber(t.strong_threshold) or 50
  self.auto_threshold = tonumber(t.auto_match_threshold) or 80
  return self
end

function M:_w(key, default)
  local v = tonumber(self.w[key])
  if v then return math.floor(v) end
  return default or 0
end

-- Precomputes clip-only fields once per clip (not per clip × file).
function M:_prep_clip(cs)
  cs = cs or {}
  local p = {}
  p.clip_uid = norm_str(cs.umid or cs.unique_id or cs.media_uid)
  p.clip_fps = to_float(cs.fps)
  local _cs_dur_s = to_float(cs.duration_seconds)
  if not _cs_dur_s then
    local cs_dur_frames = to_float(cs.duration_frames)
    if cs_dur_frames and p.clip_fps and p.clip_fps > 0 then
      _cs_dur_s = cs_dur_frames / p.clip_fps
    end
  end
  p.cs_dur_s = _cs_dur_s
  p.clip_start = cs.start_tc
  p.clip_dur = timecode.duration_to_frames(
    cs.duration_frames or cs.duration_tc or cs.duration, p.clip_fps or 0)
  p.cw, p.ch = parse_resolution(cs.resolution)
  p.clip_codec = norm_lower(cs.video_codec)
  p.clip_fmt = norm_lower(cs.file_format)
  p.clip_size = to_int(cs.file_size or cs.size)
  p.clip_reel = norm_lower(cs.reel_name)
  p.clip_serial = norm_lower(cs.camera_serial or cs.serial_number or cs.SerialNumber)
  p.clip_mtime = parse_datetime(cs.date_modified)
  p.clip_capture = parse_datetime(
    cs.shot_date or cs.date_recorded or cs.date_time_original or cs.capture_date)
  p.clip_dt = parse_datetime(cs.date_modified or cs.shot_date or cs.date_recorded)
  p.clip_ymd = ymd_of(p.clip_dt)
  p.clip_path = norm_str(cs.original_path)
  p.clip_name = basename(p.clip_path or "")
  p.clip_name_lower = p.clip_name and p.clip_name:lower() or nil
  p.clip_stamp = extract_filename_timestamp(p.clip_name)
  p.clip_stem = p.clip_name and (stem(p.clip_name) or ""):lower() or nil
  p.clip_make = norm_lower(cs.camera_make)
  p.clip_model = norm_lower(cs.camera_model)
  p.clip_bd = to_int(cs.bit_depth)
  p.clip_ch = to_int(cs.audio_channels)
  p.clip_sr = to_int(cs.audio_sample_rate or cs.AudioSampleRate)
  p.clip_abd = to_int(cs.audio_bit_depth)
  p.clip_acodec = norm_lower(cs.audio_codec)
  p.shot_take = {}
  for _, key in ipairs({"shot","scene","take","angle","camera_number"}) do
    p.shot_take[key] = norm_lower(cs[key])
  end
  return p
end

-- Mirror of _prep_clip for file metadata; cached in the file index.
local function _prep_file(meta, path)
  local m = meta or {}
  local p = {}
  p.file_uid = norm_str(m.UniqueID or m.MediaUID or m.DocumentID or m.umid)
  p.file_fps = to_float(m.VideoFrameRate or m.FrameRate or m.fps)
  p.precise_fps = to_float(m.VideoFrameRate or m.FrameRate)
  p.fm_dur_s = to_float(m.DurationSeconds or m.MediaDuration or m.TrackDuration or m.Duration)
  p.file_dur_seconds = to_float(m.MediaDuration or m.TrackDuration or m.Duration or m.duration)
  p.file_dur_raw = m.MediaDuration or m.TrackDuration or m.Duration or m.duration
  p.file_start = m.StartTimecode or m.TimeCode or m.start_tc
  local fw, fh = parse_resolution(m.ImageSize)
  if not fw then
    fw = to_int(m.ImageWidth)
    fh = to_int(m.ImageHeight)
  end
  p.fw, p.fh = fw, fh
  p.file_codec = norm_lower(m.CompressorID or m.VideoCodec or m.video_codec)
  p.file_fmt = norm_lower(m.FileType or m.file_format)
  p.f_size_meta = to_int(m.FileSize or m.file_size)
  p.file_reel = norm_lower(m.ReelName or m.reel_name)
  p.file_serial = norm_lower(m.SerialNumber or m.InternalSerialNumber or m.CameraSerialNumber)
  p.file_mtime = parse_datetime(m.FileModifyDate)
  p.file_capture = parse_datetime(
    m.DateTimeOriginal or m.CreateDate or m.MediaCreateDate or m.ModifyDate)
  p.file_dt = parse_datetime(m.FileModifyDate or m.DateTimeOriginal or m.CreateDate)
  p.file_ymd = ymd_of(p.file_dt)
  local fname = basename(path or "")
  p.f_name = fname
  p.f_name_lower = fname and fname:lower() or nil
  p.file_stamp = extract_filename_timestamp(fname)
  p.fs_stem = fname and (stem(fname) or ""):lower() or ""
  p.file_make = norm_lower(m.Make)
  p.file_model = norm_lower(m.CameraModelName or m.Model)
  p.file_bd = to_int(m.BitsPerSample or m.BitDepth)
  p.file_ch = to_int(m.AudioChannels or m.audio_channels)
  p.file_sr = to_int(m.AudioSampleRate or m.audio_sample_rate)
  p.file_abd = to_int(m.AudioBitsPerSample or m.audio_bit_depth)
  p.file_acodec = norm_lower(m.AudioFormat or m.audio_codec)
  p.shot_take = {}
  for _, key in ipairs({"shot","scene","take","angle","camera_number"}) do
    local Key = key:gsub("^%l", string.upper)
    p.shot_take[key] = norm_lower(m[key] or m[Key])
  end
  return p
end

-- Index files by rounded-duration bucket and cache per-file preps.
-- Memoized on the files_with_meta identity.
function M:_build_file_index(files_with_meta)
  if self._indexed_files == files_with_meta then return self._file_index end
  local idx = {by_bucket = {}, no_duration = {}, preps = {}}
  for path, meta in pairs(files_with_meta or {}) do
    local fp = _prep_file(meta, path)
    idx.preps[path] = fp
    if fp.fm_dur_s then
      local b = math.floor(fp.fm_dur_s + 0.5)
      idx.by_bucket[b] = idx.by_bucket[b] or {}
      idx.by_bucket[b][path] = meta
    else
      idx.no_duration[path] = meta
    end
  end
  self._indexed_files = files_with_meta
  self._file_index = idx
  return idx
end

function M:score(clip_signature, file_metadata, file_path, prep, fprep)
  local cs = clip_signature or {}
  prep = prep or self:_prep_clip(cs)
  local fm = file_metadata or {}
  fprep = fprep or _prep_file(fm, file_path)
  local reasons = {}
  local total = 0
  local function add(pts, label)
    if pts and pts > 0 then
      total = total + pts
      table.insert(reasons, string.format("%s: +%d", label, pts))
    end
  end

  local clip_uid = prep.clip_uid
  local file_uid = fprep.file_uid
  if clip_uid and file_uid and clip_uid == file_uid then
    add(self:_w("umid_exact", 100), "UMID/UID exact")
    return total, reasons
  end

  if prep.cs_dur_s and fprep.fm_dur_s
      and math.abs(prep.cs_dur_s - fprep.fm_dur_s) > 1.0 then
    table.insert(reasons, string.format(
      "FAST-REJECT: duration %.2fs vs %.2fs (> 1.0s)", prep.cs_dur_s, fprep.fm_dur_s))
    return -1000, reasons
  end

  local clip_fps = prep.clip_fps
  local file_fps = fprep.file_fps
  local eff_fps = clip_fps or file_fps

  if clip_fps and file_fps and math.abs(clip_fps - file_fps) >= 0.5 then
    local penalty = self:_w("fps_mismatch_penalty", -20)
    if penalty ~= 0 then
      total = total + penalty
      table.insert(reasons, string.format("FPS mismatch (%.2f vs %.2f): %d",
        clip_fps, file_fps, penalty))
    end
  end

  local clip_start = prep.clip_start
  local file_start = fprep.file_start
  local start_match = false
  if clip_start and file_start and eff_fps then
    local cf = timecode.parse(tostring(clip_start), eff_fps)
    local ff = timecode.parse(tostring(file_start), eff_fps)
    if cf and ff and cf == ff then start_match = true end
  end

  local clip_dur = prep.clip_dur
  local file_dur_seconds = fprep.file_dur_seconds
  local precise_fps = fprep.precise_fps or clip_fps
  local file_dur
  if file_dur_seconds and precise_fps and precise_fps > 0 then
    file_dur = math.floor(file_dur_seconds * precise_fps + 0.5)
  else
    file_dur = timecode.duration_to_frames(fprep.file_dur_raw, eff_fps or 0)
  end

  local duration_delta
  if clip_dur and file_dur then duration_delta = math.abs(clip_dur - file_dur) end

  local gate_frames = self:_w("duration_gate_frames", 30)
  if clip_dur and file_dur and duration_delta > gate_frames then
    table.insert(reasons, string.format(
      "REJECTED: duration delta %d frames > gate %d (clip=%d file=%d @ %.3f fps)",
      duration_delta, gate_frames, clip_dur, file_dur, clip_fps or 0))
    return -1000, reasons
  end
  if clip_dur and not file_dur then
    table.insert(reasons, "WARN: file duration unavailable — cannot verify")
  end

  local duration_exact_match = (duration_delta == 0)
  if start_match and duration_delta == 0 then
    add(self:_w("tc_duration_exact", 80), "Start TC + duration exact")
  else
    if start_match then add(self:_w("start_tc_exact", 40), "Start TC exact") end
    if duration_delta then
      if duration_delta == 0 then
        add(self:_w("duration_frame_exact", 30), "Duration frame-exact")
      elseif duration_delta <= 1 then
        add(self:_w("duration_within_1_frame", 20), "Duration within 1 frame")
      elseif duration_delta <= 3 then
        add(self:_w("duration_within_3_frames", 10), "Duration within 3 frames")
      elseif duration_delta <= 10 then
        add(self:_w("duration_within_10_frames", 5), "Duration within 10 frames")
      elseif duration_delta <= 30 then
        add(self:_w("duration_within_30_frames", 2), "Duration within 30 frames")
      end
    end
  end

  local cw, ch = prep.cw, prep.ch
  local fw, fh = fprep.fw, fprep.fh
  if cw and fw then
    if cw == fw and ch == fh then
      add(self:_w("resolution_exact", 15), "Resolution exact")
    elseif cw == fh and ch == fw then
      add(self:_w("resolution_rotated", 10), "Resolution rotated (portrait/landscape swap)")
    end
  end

  if prep.clip_codec and fprep.file_codec and prep.clip_codec == fprep.file_codec then
    add(self:_w("codec_exact", 10), "Video codec exact")
  end

  if prep.clip_fmt and fprep.file_fmt and prep.clip_fmt == fprep.file_fmt then
    add(self:_w("file_format_exact", 5), "File format exact")
  end

  local clip_size = prep.clip_size
  local f_size = fprep.f_size_meta
  if not f_size and file_path then f_size = file_size(file_path) end
  if clip_size and f_size then
    if clip_size == f_size then
      add(self:_w("size_exact", 15), "File size exact")
    else
      local diff = math.abs(clip_size - f_size)
      if diff / math.max(clip_size, f_size) <= 0.01 then
        add(self:_w("size_within_1pct", 3), "File size within 1%")
      end
    end
  end

  if prep.clip_reel and fprep.file_reel and prep.clip_reel == fprep.file_reel then
    add(self:_w("reel_name_exact", 35), "Reel Name exact")
  end

  local clip_serial = prep.clip_serial
  local file_serial = fprep.file_serial

  -- Pair like-with-like so local-time mtime isn't compared against UTC CreateDate.
  local mtime_delta
  if prep.clip_mtime and fprep.file_mtime then
    mtime_delta = math.abs(prep.clip_mtime - fprep.file_mtime)
  end
  local capture_delta
  if prep.clip_capture and fprep.file_capture then
    capture_delta = math.abs(prep.clip_capture - fprep.file_capture)
  end
  local date_delta
  if mtime_delta then date_delta = mtime_delta end
  if capture_delta and (not date_delta or capture_delta < date_delta) then
    date_delta = capture_delta
  end

  local date_same_day = (prep.clip_ymd and fprep.file_ymd
    and prep.clip_ymd == fprep.file_ymd) or false

  if clip_serial and file_serial and clip_serial == file_serial and date_same_day then
    add(self:_w("camera_serial_date", 80), "Camera serial + date")
  end

  if date_delta and date_delta < 1 and date_same_day then
    add(self:_w("datetime_combo", 70), "Date + time exact")
  elseif date_same_day and date_delta and date_delta <= 5 then
    add(self:_w("time_within_5s_same_day", 30), "Same date, time within 5s")
  elseif date_same_day and date_delta and date_delta <= 60 then
    add(self:_w("time_within_1m_same_day", 25), "Same date, time within 1m")
  elseif date_same_day then
    add(self:_w("date_same_day", 15), "Date exact (same day)")
  elseif date_delta and date_delta <= 3600 then
    add(self:_w("datetime_within_1h", 8), "Date close (within 1h)")
  end

  if date_same_day and duration_exact_match then
    add(self:_w("date_duration_combo", 15), "Date + duration combo bonus")
  end

  local clip_name_lower = prep.clip_name_lower
  local f_name_lower = fprep.f_name_lower
  local clip_stamp = prep.clip_stamp
  local file_stamp = fprep.file_stamp
  if clip_name_lower and f_name_lower then
    if clip_name_lower == f_name_lower then
      add(self:_w("filename_exact", 10), "Filename exact")
    elseif clip_stamp and file_stamp and clip_stamp == file_stamp then
      add(self:_w("filename_timestamp_exact", 8), "Filename timestamp exact")
    elseif clip_stamp and file_stamp and math.abs(clip_stamp - file_stamp) <= 2 then
      add(self:_w("filename_timestamp_2s", 4), "Filename timestamp within 2s")
    else
      local cs_stem = prep.clip_stem or ""
      local fs_stem = fprep.fs_stem
      if levenshtein.distance(cs_stem, fs_stem) <= 3 then
        add(self:_w("filename_fuzzy", 3), "Filename fuzzy")
      end
    end
  end

  if prep.clip_make and fprep.file_make and prep.clip_make == fprep.file_make then
    add(self:_w("camera_make_exact", 5), "Camera make exact")
  end

  if prep.clip_model and fprep.file_model and prep.clip_model == fprep.file_model then
    add(self:_w("camera_model_exact", 10), "Camera model exact")
  end

  if prep.clip_bd and fprep.file_bd and prep.clip_bd == fprep.file_bd then
    add(self:_w("bit_depth_exact", 3), "Bit depth exact")
  end

  for _, key in ipairs({"shot", "scene", "take", "angle", "camera_number"}) do
    local cv = prep.shot_take[key]
    local fv = fprep.shot_take[key]
    if cv and fv and cv == fv then
      add(self:_w(key .. "_exact", 8), key:gsub("^%l", string.upper) .. " exact")
    end
  end

  if prep.clip_ch and fprep.file_ch and prep.clip_ch == fprep.file_ch then
    add(self:_w("audio_ch_exact", 5), "Audio channels exact")
  end

  if prep.clip_sr and fprep.file_sr and prep.clip_sr == fprep.file_sr then
    add(self:_w("audio_sr_exact", 3), "Audio sample rate exact")
  end

  if prep.clip_abd and fprep.file_abd and prep.clip_abd == fprep.file_abd then
    add(self:_w("audio_bit_depth_exact", 2), "Audio bit depth exact")
  end

  if prep.clip_acodec and fprep.file_acodec and prep.clip_acodec == fprep.file_acodec then
    add(self:_w("audio_codec_exact", 3), "Audio codec exact")
  end

  if clip_fps and file_fps and math.abs(clip_fps - file_fps) < 0.01 then
    add(self:_w("fps_exact", 5), "FPS exact")
  end

  return total, reasons
end

function M:rank_candidates(clip_signature, files_with_meta)
  local results = {}
  local all_scores = {}
  local fast_rejected = 0
  local timings = {}
  local t_start = os.clock()

  local t0 = os.clock()
  local prep = self:_prep_clip(clip_signature)
  timings.prep_clip = os.clock() - t0

  t0 = os.clock()
  local idx = self:_build_file_index(files_with_meta)
  timings.build_index = os.clock() - t0
  local preps = idx.preps

  local scored_count = 0
  local function score_one(path, meta)
    scored_count = scored_count + 1
    local sc, reasons = self:score(clip_signature, meta or {}, path, prep, preps[path])
    if sc >= self.weak_threshold then
      local rec = {
        path = path,
        score = sc,
        reasons = reasons,
        metadata = meta or {},
        ambiguous = false,
      }
      table.insert(results, rec)
      table.insert(all_scores, rec)
    elseif sc > -1000 then
      table.insert(all_scores, {path = path, score = sc})
    else
      fast_rejected = fast_rejected + 1
    end
  end

  t0 = os.clock()
  local bucket_files = 0
  if prep.cs_dur_s then
    local b = math.floor(prep.cs_dur_s + 0.5)
    for _, db in ipairs({b - 1, b, b + 1}) do
      local bucket = idx.by_bucket[db]
      if bucket then
        for path, meta in pairs(bucket) do
          bucket_files = bucket_files + 1
          score_one(path, meta)
        end
      end
    end
    for path, meta in pairs(idx.no_duration) do
      bucket_files = bucket_files + 1
      score_one(path, meta)
    end
  else
    for _, bucket in pairs(idx.by_bucket) do
      for path, meta in pairs(bucket) do
        bucket_files = bucket_files + 1
        score_one(path, meta)
      end
    end
    for path, meta in pairs(idx.no_duration) do
      bucket_files = bucket_files + 1
      score_one(path, meta)
    end
  end
  timings.score_sweep = os.clock() - t0
  timings.bucket_files = bucket_files

  if fast_rejected > 0 then
    all_scores._gate_rejected = fast_rejected
  end
  all_scores._scored_count = scored_count

  t0 = os.clock()
  table.sort(results, function(a, b) return a.score > b.score end)
  table.sort(all_scores, function(a, b) return a.score > b.score end)
  timings.sort = os.clock() - t0

  timings.total = os.clock() - t_start
  results._all_scores = all_scores
  results._weak_threshold = self.weak_threshold
  results._timings = timings
  return results
end

function M:match_all(clip_signatures, files_with_meta)
  local results = {}
  for _, sig in ipairs(clip_signatures or {}) do
    local clip_id = sig.id
    local candidates = self:rank_candidates(sig, files_with_meta)
    if candidates[1] and candidates[2]
        and candidates[1].score >= self.auto_threshold
        and candidates[1].score == candidates[2].score then
      for _, c in ipairs(candidates) do
        if c.score == candidates[1].score then c.ambiguous = true end
      end
    end
    results[clip_id] = candidates
  end
  local top_owners = {}
  for cid, cands in pairs(results) do
    if cands[1] and cands[1].score >= self.auto_threshold then
      local p = cands[1].path
      top_owners[p] = top_owners[p] or {}
      table.insert(top_owners[p], cid)
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
  for _, cands in pairs(results) do
    for _, c in ipairs(cands) do
      if c["one-source-multiple-clips"] == nil then
        c["one-source-multiple-clips"] = false
      end
    end
  end
  return results
end

function M.build_default()
  local cfg = config.load_config()
  return M.new(cfg.weights or {}, {
    auto_match_threshold = cfg.auto_match_threshold or 80,
    strong_threshold = cfg.strong_threshold or 50,
    weak_threshold = cfg.weak_threshold or 20,
  })
end

return M
