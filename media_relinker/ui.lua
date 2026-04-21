local config = require("media_relinker.config")
local History = require("media_relinker.history")
local RelinkLog = require("media_relinker.relink_log")
local logger = require("media_relinker.logger").get_logger("media_relinker.ui")

local M = {}

local function get_fusion(resolve_handle)
  local ok_bmd, bmd_mod = pcall(function() return bmd end)
  if not ok_bmd or not bmd_mod then
    logger.warn("get_fusion: bmd global not available")
    return nil
  end
  local resolve = resolve_handle
  if not resolve then
    local r_ok, r_val = pcall(function() return _G.resolve end)
    if r_ok and r_val then resolve = r_val end
  end
  if not resolve and bmd_mod.scriptapp then
    local ok, r = pcall(bmd_mod.scriptapp, "Resolve")
    if ok then resolve = r end
  end
  if not resolve then
    logger.warn("get_fusion: could not obtain Resolve handle")
    return nil
  end
  local fu_ok, fusion = pcall(function() return resolve:Fusion() end)
  if not fu_ok or not fusion then
    logger.warn("get_fusion: resolve:Fusion() failed: %s", tostring(fusion))
    return nil
  end
  local ui = fusion.UIManager
  if not ui then
    logger.warn("get_fusion: fusion.UIManager missing")
    return nil
  end
  local disp_ok, disp = pcall(function() return bmd_mod.UIDispatcher(ui) end)
  if not disp_ok or not disp then
    logger.warn("get_fusion: UIDispatcher failed: %s", tostring(disp))
    return nil
  end
  logger.info("get_fusion: Fusion UI stack acquired successfully")
  return {ui = ui, disp = disp, bmd = bmd_mod, fusion = fusion, resolve = resolve}
end

function M.show_message(title, msg, kind)
  local fu = get_fusion(nil)
  if fu and fu.ui and fu.disp then
    -- bmd.AskUser with a Message/Text widget opens an empty/invisible dialog
    -- on some Resolve builds; a real UIManager window reliably appears.
    local ok_built, err = pcall(function()
      local ui, disp = fu.ui, fu.disp
      local win_id = "com.jesseb.media_relinker.msg_" .. tostring(os.time())
      local w = disp:AddWindow({
        ID = win_id,
        WindowTitle = title or "Media Relinker",
        Geometry = {400, 300, 480, 180},
      }, ui:VGroup{
        ui:TextEdit{ID = "Msg", Text = msg or "", ReadOnly = true},
        ui:HGroup{Weight = 0, ui:HGap(0, 1),
          ui:Button{ID = "OkBtn", Text = "OK", Weight = 0}},
      })
      local closers = {
        [win_id] = {Close = function() disp:ExitLoop() end},
        OkBtn = {Clicked = function() disp:ExitLoop() end},
      }
      for id, events in pairs(closers) do
        for ev, fn in pairs(events) do
          pcall(function() w.On[id][ev] = fn end)
        end
      end
      w:Show()
      disp:RunLoop()
      w:Hide()
    end)
    if ok_built then return end
    logger.warn("show_message UI failed: %s — falling back to bmd.AskUser", tostring(err))
  end
  if fu and fu.bmd and fu.bmd.AskUser then
    pcall(function()
      fu.bmd.AskUser(title or "Media Relinker", {
        ["1"] = {[1] = "Message", [2] = "Text", Default = msg or ""},
      })
    end)
    return
  end
  io.stderr:write(string.format("[%s] %s: %s\n", kind or "info", title or "", msg or ""))
end

local function basename(p)
  if not p then return "" end
  return (tostring(p):match("([^/\\]+)$")) or tostring(p)
end

local function split_lines(s)
  local out = {}
  for line in (s or ""):gmatch("[^\r\n]+") do table.insert(out, line) end
  return out
end

local function open_path(path)
  if not path or path == "" then return false end
  local is_win = package.config:sub(1, 1) == "\\"
  local cmd
  if is_win then
    local p = path:gsub('"', '')
    cmd = 'start "" "' .. p .. '"'
  else
    local q = "'" .. path:gsub("'", "'\\''") .. "'"
    cmd = "(command -v open >/dev/null 2>&1 && open " .. q ..
          ") || xdg-open " .. q .. " >/dev/null 2>&1"
  end
  logger.info("open_path: %s", path)
  local ok = os.execute(cmd)
  return ok == true or ok == 0
end
M.open_path = open_path

local function first_of(tbl, keys)
  if not tbl then return nil end
  for _, k in ipairs(keys) do
    local v = tbl[k]
    if v ~= nil and v ~= "" then return v end
  end
  return nil
end

-- Resolve and exiftool name the same codec differently; normalise so
-- "H.265 Main 10 L5.2" and "hvc1" both resolve to "HEVC".
local function canon_codec(s)
  if not s then return nil end
  local low = tostring(s):lower()
  if low:find("hevc") or low:find("h%.?265") or low:find("hvc1") or low:find("hev1") then return "HEVC" end
  if low:find("h%.?264") or low:find("avc1") or low:find("^avc") then return "H.264" end
  if low:find("prores") then return "ProRes" end
  if low:find("dnx")    then return "DNx" end
  if low:find("mjpeg")  or low:find("mjpa") then return "MJPEG" end
  if low:find("av1")    then return "AV1" end
  return nil  -- unknown -> fall back to raw-string compare
end

local function pair_cell(a, b, equiv)
  a = tostring(a or "-")
  b = tostring(b or "-")
  local same
  if equiv ~= nil then
    same = equiv
  else
    same = (a:lower() == b:lower())
  end
  if same then
    local trimmed = a:match("^%s*(.-)%s*$")
    return trimmed ~= "" and trimmed or a
  end
  return a .. " | " .. b
end

local QUALITY_COLOR = {
  exact = {R = 0.35, G = 0.85, B = 0.45, A = 1.0},
  close = {R = 0.95, G = 0.82, B = 0.35, A = 1.0},
  far   = {R = 0.95, G = 0.45, B = 0.45, A = 1.0},
}
local QUALITY_MARK = {exact = "✓ ", close = "~ ", far = "✗ "}

local function quality_prefix(text, quality)
  if not quality or not QUALITY_MARK[quality] then return text end
  return QUALITY_MARK[quality] .. text
end

local function apply_quality(item, col, quality)
  if not quality then return end
  local colour = QUALITY_COLOR[quality]
  if not colour then return end
  pcall(function() item.TextColor[col] = colour end)
end

local function fmt_duration_cell(sig, meta)
  local clip_frames = tonumber(first_of(sig, {"duration_frames"}))
  -- Prefer the video track's own media duration; movie-level Duration drifts
  -- 1-3 frames. Matches matcher.lua.
  local file_secs = tonumber(first_of(meta, {"MediaDuration", "TrackDuration", "Duration"}))
  local fps = tonumber(first_of(meta, {"VideoFrameRate", "FrameRate"})
    or first_of(sig, {"fps"}))
  -- Pad numeric prefix so the tree's lexicographic column sort orders
  -- numerically (otherwise "50f" ranks above "100f").
  local clip_str = clip_frames and string.format("%7df", clip_frames) or "      -"
  local file_frames
  if file_secs and fps and fps > 0 then
    file_frames = math.floor(file_secs * fps + 0.5)
  end
  local file_str
  if file_frames then
    file_str = string.format("%7df", file_frames)
  elseif file_secs then
    file_str = string.format("%9.2fs", file_secs)
  else
    file_str = "      -"
  end
  local same = clip_frames and file_frames and clip_frames == file_frames
  local quality
  if clip_frames and file_frames then
    local diff = math.abs(clip_frames - file_frames)
    if diff == 0 then quality = "exact"
    elseif diff <= 2 then quality = "close"
    else quality = "far" end
  end
  return pair_cell(clip_str, file_str, same), quality
end

local function fmt_resolution_cell(sig, meta)
  local clip_res = tostring(first_of(sig, {"resolution"}) or "-")
  local file_res = first_of(meta, {"ImageSize"})
  if not file_res then
    local w = first_of(meta, {"ImageWidth"})
    local h = first_of(meta, {"ImageHeight"})
    if w and h then file_res = w .. "x" .. h end
  end
  local quality
  if clip_res ~= "-" and file_res then
    local cw, ch = clip_res:match("(%d+)[x×](%d+)")
    local fw, fh = tostring(file_res):match("(%d+)[x× ](%d+)")
    if cw and fw then
      if cw == fw and ch == fh then
        quality = "exact"
      elseif cw == fh and ch == fw then
        -- Portrait/landscape swap: same pixels, rotated.
        quality = "close"
      else
        local cr = tonumber(cw) / math.max(tonumber(ch), 1)
        local fr = tonumber(fw) / math.max(tonumber(fh), 1)
        quality = math.abs(cr - fr) < 0.05 and "close" or "far"
      end
    end
  end
  return pair_cell(clip_res, file_res or "-"), quality
end

-- Compare Resolve's "Date Modified" (on-disk mtime, local time) against
-- exiftool's FileModifyDate (same thing). QuickTime CreateDate is UTC and
-- produced misleading multi-hour "mismatches" on non-UTC footage.
-- Normalise Resolve's "Fri May 16 11:55:41 2025", exiftool's
-- "2025:05:16 11:55:41+11:00" and ISO strings to "YYYY-MM-DD HH:MM:SS".
local MONTHS_UI = {Jan=1,Feb=2,Mar=3,Apr=4,May=5,Jun=6,
                   Jul=7,Aug=8,Sep=9,Oct=10,Nov=11,Dec=12}
local function fmt_date(v)
  if not v then return "-" end
  local s = tostring(v):match("^%s*(.-)%s*$")
  if s == "" or s == "-" then return "-" end
  s = s:gsub("Z$", ""):gsub("([+-]%d%d):?(%d%d)$", "")
  local Y, Mo, D, h, mi, se = s:match("^(%d%d%d%d)[:%-](%d%d)[:%-](%d%d)[T ](%d%d):(%d%d):(%d%d)")
  if Y then return string.format("%s-%s-%s %s:%s:%s", Y, Mo, D, h, mi, se) end
  local Mon, Dd, hh, mm, ss, Yy = s:match("^%a+%s+(%a+)%s+(%d+)%s+(%d+):(%d+):(%d+)%s+(%d%d%d%d)$")
  if Mon and MONTHS_UI[Mon] then
    return string.format("%s-%02d-%02d %02d:%02d:%02d",
      Yy, MONTHS_UI[Mon], tonumber(Dd), tonumber(hh), tonumber(mm), tonumber(ss))
  end
  Mon, Dd, Yy, hh, mm, ss = s:match("^%a+%s+(%a+)%s+(%d+)%s+(%d%d%d%d)%s+(%d+):(%d+):(%d+)$")
  if Mon and MONTHS_UI[Mon] then
    return string.format("%s-%02d-%02d %02d:%02d:%02d",
      Yy, MONTHS_UI[Mon], tonumber(Dd), tonumber(hh), tonumber(mm), tonumber(ss))
  end
  return tostring(v)
end

local function split_datetime(s)
  if not s or s == "-" then return "-", "-" end
  local d, t = s:match("^(%S+)%s+(%S+)$")
  if d and t then return d, t end
  return s, "-"
end

-- Normalise the raw additive score to a 0-100% confidence reading: the
-- auto-match threshold maps to 100%, everything below scales proportionally.
-- Padded so lexicographic tree sort matches numeric order.
local function fmt_confidence(score, auto_threshold)
  local s = tonumber(score) or 0
  local t = tonumber(auto_threshold) or 80
  if t <= 0 then t = 80 end
  local pct = math.floor(math.min(100, math.max(0, s / t * 100)) + 0.5)
  return string.format("%3d%%", pct)
end

-- Map confidence to a QUALITY_COLOR bucket: >=100% exact (cleared auto
-- threshold), 60-99% close, below far.
local function confidence_quality(score, auto_threshold)
  local s = tonumber(score) or 0
  local t = tonumber(auto_threshold) or 80
  if t <= 0 then t = 80 end
  local pct = s / t * 100
  if pct >= 100 then return "exact"
  elseif pct >= 60 then return "close"
  else return "far" end
end

local function _days_between(d1, d2)
  local Y1, M1, D1 = d1:match("^(%d%d%d%d)-(%d%d)-(%d%d)")
  local Y2, M2, D2 = d2:match("^(%d%d%d%d)-(%d%d)-(%d%d)")
  if not (Y1 and Y2) then return nil end
  local t1 = os.time{year=tonumber(Y1), month=tonumber(M1), day=tonumber(D1), hour=12}
  local t2 = os.time{year=tonumber(Y2), month=tonumber(M2), day=tonumber(D2), hour=12}
  return math.abs(os.difftime(t1, t2) / 86400)
end

local function _seconds_between(t1, t2)
  local h1, m1, s1 = t1:match("^(%d+):(%d+):(%d+)")
  local h2, m2, s2 = t2:match("^(%d+):(%d+):(%d+)")
  if not (h1 and h2) then return nil end
  local a = tonumber(h1) * 3600 + tonumber(m1) * 60 + tonumber(s1)
  local b = tonumber(h2) * 3600 + tonumber(m2) * 60 + tonumber(s2)
  return math.abs(a - b)
end

local function fmt_date_only_cell(sig, meta)
  local clip_d = fmt_date(first_of(sig, {"date_modified"}))
  local file_d = fmt_date(first_of(meta, {"FileModifyDate"}))
  local cd = select(1, split_datetime(clip_d))
  local fd = select(1, split_datetime(file_d))
  local quality
  if cd ~= "-" and fd ~= "-" then
    if cd == fd then
      quality = "exact"
    else
      local dd = _days_between(cd, fd)
      if dd and dd <= 7 then quality = "close" else quality = "far" end
    end
  end
  return pair_cell(cd, fd, cd == fd and cd ~= "-"), quality
end

local function fmt_time_only_cell(sig, meta)
  local clip_d = fmt_date(first_of(sig, {"date_modified"}))
  local file_d = fmt_date(first_of(meta, {"FileModifyDate"}))
  local ct = select(2, split_datetime(clip_d))
  local ft = select(2, split_datetime(file_d))
  local quality
  if ct ~= "-" and ft ~= "-" then
    if ct == ft then
      quality = "exact"
    else
      local ds = _seconds_between(ct, ft)
      if ds and ds <= 60 then quality = "close" else quality = "far" end
    end
  end
  return pair_cell(ct, ft, ct == ft and ct ~= "-"), quality
end

local function fmt_codec_cell(sig, meta)
  local clip_c = tostring(first_of(sig, {"video_codec"}) or "-")
  local file_c = tostring(first_of(meta, {"CompressorID", "VideoCodec"}) or "-")
  local ca, fa = canon_codec(clip_c), canon_codec(file_c)
  local same
  if ca and fa then same = (ca == fa)
  else same = (clip_c:lower() == file_c:lower()) end
  return pair_cell(clip_c, file_c, same)
end

local function fmt_fps_cell(sig, meta)
  local c = tonumber(first_of(sig, {"fps"}))
  local f = tonumber(first_of(meta, {"VideoFrameRate", "FrameRate"}))
  local cs = c and (string.format("%.3f", c):gsub("%.?0+$", "")) or "-"
  local fs = f and (string.format("%.3f", f):gsub("%.?0+$", "")) or "-"
  local same = c and f and math.abs(c - f) < 0.01
  local quality
  if c and f then
    local diff = math.abs(c - f)
    if diff < 0.01 then quality = "exact"
    elseif diff < 0.1 then quality = "close"
    else quality = "far" end
  end
  return pair_cell(cs, fs, same), quality
end

local RelinkerWindow = {}
RelinkerWindow.__index = RelinkerWindow

function M.new(clips, callbacks, resolve_handle)
  local self = setmetatable({}, RelinkerWindow)
  self.clips = clips or {}
  self.callbacks = callbacks or {}
  self.results = {}
  self.selected_candidate = {}
  self.cancel_flag = false
  self._fu = get_fusion(resolve_handle)
  if self._fu then
    logger.info("UI mode: Fusion GUI")
  else
    logger.warn("UI mode: console fallback (Fusion UI unavailable)")
  end
  return self
end

function RelinkerWindow:show()
  if self._fu then
    local ok, err = pcall(function() self:_run_fusion() end)
    if not ok then
      logger.error("Fusion UI failed: %s", tostring(err))
      M.show_message("Media Relinker", "UI error: " .. tostring(err), "error")
    end
  else
    self:_run_console()
  end
end

function RelinkerWindow:_bucket(score, auto_t, strong_t)
  if not score then return "none" end
  if score >= auto_t then return "high" end
  if score >= strong_t then return "medium" end
  return "low"
end

function RelinkerWindow:_populate_tree(tree, show_filters)
  pcall(function() tree:Clear() end)
  local cfg = config.load_config()
  local auto_t = cfg.auto_match_threshold or 80
  local strong_t = cfg.strong_threshold or 50

  -- Maps tree items back to (info_id, candidate) for checkbox toggle handlers.
  self._item_binding = {}
  self._top_item_by_info_id = {}

  local function fill_comparison_cells(item, sig, meta)
    local dur_txt, dur_q = fmt_duration_cell(sig, meta)
    local fps_txt, fps_q = fmt_fps_cell(sig, meta)
    local date_txt, date_q = fmt_date_only_cell(sig, meta)
    local time_txt, time_q = fmt_time_only_cell(sig, meta)
    local res_txt, res_q = fmt_resolution_cell(sig, meta)
    item.Text[4] = quality_prefix(dur_txt, dur_q)
    item.Text[5] = quality_prefix(fps_txt, fps_q)
    item.Text[6] = quality_prefix(date_txt, date_q)
    item.Text[7] = quality_prefix(time_txt, time_q)
    item.Text[8] = quality_prefix(res_txt, res_q)
    apply_quality(item, 4, dur_q)
    apply_quality(item, 5, fps_q)
    apply_quality(item, 6, date_q)
    apply_quality(item, 7, time_q)
    apply_quality(item, 8, res_q)
  end

  for _, info in ipairs(self.clips) do
    local cands = self.results[info.id] or {}
    local top = cands[1]
    local bucket = top and self:_bucket(top.score, auto_t, strong_t) or "none"
    local sig = info.signature or {}

    if show_filters[bucket] then
      local ok, err = pcall(function()
        local item = tree:NewItem()
        item.Text[0] = ""
        item.Text[1] = info.name or ""
        if top then
          local label = basename(top.path)
          if top.ambiguous then
            local strong_n = 0
            for _, c in ipairs(cands) do
              if c.score >= auto_t then strong_n = strong_n + 1 end
            end
            label = string.format("? %s - ambiguous (%d files at %d+)",
              basename(top.path), strong_n, auto_t)
          end
          if top["one-source-multiple-clips"] then
            label = "[shared] " .. label
          end
          item.Text[2] = label
          item.Text[3] = fmt_confidence(top.score, auto_t)
          apply_quality(item, 3, confidence_quality(top.score, auto_t))
          pcall(function()
            item.TextColor[2] = {R = 0.45, G = 0.75, B = 1.0, A = 1.0}
            item.ToolTip[2] = "Click to open: " .. tostring(top.path)
          end)
          fill_comparison_cells(item, sig, top.metadata or {})
          local should_check = (top.score >= auto_t) and not top.ambiguous
          item.CheckState[0] = should_check and "Checked" or "Unchecked"
          self.selected_candidate[info.id] = should_check and top or nil
          self._item_binding[item] = {info_id = info.id, cand = top}
        else
          item.Text[2] = "(no match found)"
          item.Text[3] = "-"
          fill_comparison_cells(item, sig, {})
          item.CheckState[0] = "Unchecked"
          self.selected_candidate[info.id] = nil
        end
        -- Cap rendered children: Fusion's tree repaints on each AddChild and
        -- weak-candidate counts routinely hit the hundreds per clip. Full
        -- list stays in self.results for re-pick/history.
        local MAX_CHILDREN = 10
        local child_limit = math.min(#cands, 1 + MAX_CHILDREN)
        for i = 2, child_limit do
          local c = cands[i]
          local child = tree:NewItem()
          child.Text[1] = ""
          child.Text[2] = basename(c.path) .. "  [" .. table.concat(c.reasons or {}, ", ") .. "]"
          child.Text[3] = fmt_confidence(c.score, auto_t)
          apply_quality(child, 3, confidence_quality(c.score, auto_t))
          pcall(function()
            child.TextColor[2] = {R = 0.45, G = 0.75, B = 1.0, A = 1.0}
            child.ToolTip[2] = "Click to open: " .. tostring(c.path)
          end)
          fill_comparison_cells(child, sig, c.metadata or {})
          child.CheckState[0] = "Unchecked"
          item:AddChild(child)
          self._item_binding[child] = {info_id = info.id, cand = c}
        end
        tree:AddTopLevelItem(item)
        self._top_item_by_info_id[info.id] = item
      end)
      if not ok then logger.debug("Tree item failure: %s", tostring(err)) end
    end
  end
end

function RelinkerWindow:_collect_selections()
  local selections = {}
  for _, info in ipairs(self.clips) do
    local cand = self.selected_candidate[info.id]
    if cand then
      -- Capture other candidates so history's "Re-pick alternative" works
      -- without a re-scan.
      local alts = {}
      local all = self.results[info.id] or {}
      for _, c in ipairs(all) do
        if c.path ~= cand.path and #alts < 9 then
          table.insert(alts, {
            path = c.path, score = c.score, reasons = c.reasons or {},
          })
        end
      end
      table.insert(selections, {
        info_id = info.id,
        clip = info.clip,
        clip_name = info.name,
        new_path = cand.path,
        score = cand.score,
        reasons = cand.reasons or {},
        alternatives = alts,
      })
    end
  end
  return selections
end

function RelinkerWindow:_run_fusion()
  local ui = self._fu.ui
  local disp = self._fu.disp
  local bmd_mod = self._fu.bmd

  local win_id = "com.jesseb.media_relinker"
  local cfg_initial = config.load_config()
  local pf = cfg_initial.show_filters or {}
  local show_filters = {
    high   = pf.high   ~= false,
    medium = pf.medium ~= false,
    low    = pf.low    ~= false,
    none   = pf.none   ~= false,
  }

  local layout = ui:VGroup{
    ui:Label{Text = string.format("Offline clips in project: %d", #self.clips), Weight = 0},
    ui:HGroup{
      Weight = 0,
      ui:Label{Text = "Scan folders (one per line — click Browse to add more):", Weight = 0},
      ui:TextEdit{ID = "FolderEdit", Text = "",
        PlaceholderText = "Click 'Browse folder...' to add a folder; repeat to add more"},
      ui:VGroup{
        Weight = 0,
        ui:Button{ID = "BrowseBtn", Text = "Browse folder...", Weight = 0},
        ui:Button{ID = "RemoveFolderBtn", Text = "Clear all", Weight = 0},
      },
    },
    ui:HGroup{
      Weight = 0,
      ui:CheckBox{ID = "Recursive", Text = "Include subdirectories", Checked = true},
      ui:CheckBox{ID = "ForceRescan", Text = "Rescan from disk",
        Checked = false,
        ToolTip = "Ignore the persistent folder cache and re-walk every root."},
      ui:HGap(0, 1),
      ui:Button{ID = "ScanBtn", Text = "Scan", Weight = 0},
      ui:Button{ID = "ClearCacheBtn", Text = "Clear cache", Weight = 0},
    },
    ui:HGroup{
      Weight = 0,
      ui:Label{ID = "ProgressLabel", Text = "", Weight = 1},
    },
    ui:Tree{
      ID = "Tree",
      ColumnCount = 9,
      ColumnIconsVisible = true,
      SortingEnabled = true,
    },
    ui:HGroup{
      Weight = 0,
      ui:Button{
        ID = "ShowBtn", Text = "Show: (loading...)",
        Weight = 0,
        MinimumSize = {260, 26},
      },
      ui:HGap(0, 1),
    },
    ui:HGroup{
      Weight = 0,
      ui:Button{ID = "RelinkBtn", Text = "Relink Selected"},
      ui:Button{ID = "SettingsBtn", Text = "Settings"},
      ui:Button{ID = "HistoryBtn", Text = "History"},
      ui:Button{ID = "CloseBtn", Text = "Close"},
    },
  }

  local win = disp:AddWindow({
    ID = win_id,
    WindowTitle = "Media Relinker",
    Geometry = {200, 200, 900, 600},
  }, layout)

  local items = win:GetItems()
  local tree = items.Tree
  pcall(function()
    local hdr = tree:NewItem()
    hdr.Text[0] = ""
    hdr.Text[1] = "Offline clip"
    hdr.Text[2] = "Match"
    hdr.Text[3] = "Confidence"
    hdr.Text[4] = "Duration (offline | match)"
    hdr.Text[5] = "FPS (offline | match)"
    hdr.Text[6] = "Date (offline | match)"
    hdr.Text[7] = "Time (offline | match)"
    hdr.Text[8] = "Resolution (offline | match)"
    tree:SetHeaderItem(hdr)
  end)

  -- Pre-fill folder list with previously scanned roots so cross-project
  -- scans don't require re-typing the same paths.
  if self.callbacks.on_known_roots then
    local ok, roots = pcall(self.callbacks.on_known_roots)
    if ok and type(roots) == "table" and #roots > 0 then
      pcall(function() items.FolderEdit.Text = table.concat(roots, "\n") end)
      logger.info("Pre-filled FolderEdit with %d known root(s)", #roots)
    end
  end

  self:_populate_tree(tree, show_filters)

  local handlers = {}
  handlers[win_id] = {Close = function()
    -- Signal any in-flight scan to bail at its next cancel check, and hide
    -- the window immediately so the close feels responsive.
    self.cancel_flag = true
    pcall(function() win:Hide() end)
    disp:ExitLoop()
  end}

  local function get_folder_text()
    local fe = items.FolderEdit
    local text = fe.PlainText
    if not text or text == "" then text = fe.Text end
    return text or ""
  end

  handlers.CloseBtn = {Clicked = function()
    self.cancel_flag = true
    pcall(function() win:Hide() end)
    disp:ExitLoop()
  end}

  handlers.BrowseBtn = {Clicked = function()
    -- Prefer fusion:RequestDir; fall back to bmd.AskUser + PathBrowse on
    -- older builds that lack RequestDir.
    local folder
    local fusion = self._fu and self._fu.fusion
    if fusion and type(fusion.RequestDir) == "function" then
      local ok, r = pcall(function() return fusion:RequestDir("") end)
      logger.info("BrowseBtn: fusion:RequestDir returned ok=%s r=%s",
        tostring(ok), tostring(r))
      if ok and type(r) == "string" and r ~= "" then folder = r end
    end
    if not folder then
      local ok, result = pcall(function()
        return bmd_mod.AskUser("Scan folder", {
          ["1"] = {[1] = "Folder", [2] = "PathBrowse", Default = ""},
        })
      end)
      logger.info("BrowseBtn: bmd.AskUser fallback ok=%s folder=%s",
        tostring(ok), result and tostring(result.Folder) or "nil")
      if ok and result and result.Folder and result.Folder ~= "" then
        folder = result.Folder
      end
    end
    if not folder then
      M.show_message("Browse",
        "Folder picker returned nothing. You can also paste paths directly into the text box, one per line.")
      return
    end
    local existing = get_folder_text()
    if existing ~= "" and not existing:match("\n$") then existing = existing .. "\n" end
    items.FolderEdit.Text = existing .. folder
  end}

  handlers.RemoveFolderBtn = {Clicked = function()
    items.FolderEdit.Text = ""
  end}

  handlers.ScanBtn = {Clicked = function()
    local folders = {}
    for _, ln in ipairs(split_lines(get_folder_text())) do
      local trimmed = ln:match("^%s*(.-)%s*$")
      if trimmed ~= "" and config.is_dir(trimmed) then
        table.insert(folders, trimmed)
      end
    end
    if #folders == 0 then
      M.show_message("Scan", "Please add at least one valid folder.", "error")
      return
    end
    local recursive = items.Recursive.Checked and true or false
    local force_rescan = items.ForceRescan and items.ForceRescan.Checked and true or false
    self.cancel_flag = false
    items.ScanBtn.Text = "Scanning..."
    local fu_ref = self._fu
    local disp_ref = disp
    local status_label = items.ProgressLabel
    local function set_status(text)
      if status_label then
        pcall(function() status_label.Text = text end)
        pcall(function() status_label:SetText(text) end)
      end
      if fu_ref and fu_ref.fusion then
        pcall(function() fu_ref.fusion:ProcessEvents() end)
      end
    end
    set_status("Scanning, this may take a few minutes…")
    -- on_progress just pumps the event queue; the status text stays stable.
    local on_progress = function(phase, current, total)
      if fu_ref and fu_ref.fusion then
        pcall(function() fu_ref.fusion:ProcessEvents() end)
      end
    end
    -- Pump via every API the host exposes so a queued Close/X click can
    -- fire its handler: Resolve's embedded Fusion doesn't always dispatch
    -- UIManager clicks through fusion:ProcessEvents() alone.
    local is_cancelled = function()
      if fu_ref then
        if fu_ref.fusion then
          pcall(function() fu_ref.fusion:ProcessEvents() end)
        end
        if fu_ref.ui then
          pcall(function() fu_ref.ui:ProcessEvents() end)
        end
      end
      if disp_ref then
        pcall(function() disp_ref:ProcessEvents() end)
      end
      return self.cancel_flag
    end
    local ok, res = pcall(self.callbacks.on_scan, folders, recursive, is_cancelled, on_progress,
      {force_rescan = force_rescan})
    items.ScanBtn.Text = "Scan"
    if self.cancel_flag then
      set_status("Cancelled")
      logger.info("Scan cancelled by user — window closing")
      return
    end
    if not ok then
      set_status("Scan failed")
      M.show_message("Scan failed", tostring(res), "error")
      return
    end
    self.results = res or {}
    local matched = 0
    local total_cands = 0
    for _, cands in pairs(self.results) do
      if cands[1] then matched = matched + 1 end
      total_cands = total_cands + #cands
    end
    set_status(string.format("Done — %d / %d clips matched", matched, #self.clips))
    local _tree_t0 = os.clock()
    self:_populate_tree(tree, show_filters)
    logger.info("Tree populated: %d clips, %d total candidates in %.3fs",
      #self.clips, total_cands, os.clock() - _tree_t0)
  end}

  handlers.ClearCacheBtn = {Clicked = function()
    if self.callbacks.on_clear_cache then
      self.callbacks.on_clear_cache()
      M.show_message("Cache", "Cache cleared.")
    end
  end}

  local function update_show_btn_label()
    local all_on = show_filters.high and show_filters.medium
      and show_filters.low and show_filters.none
    if all_on then
      items.ShowBtn.Text = "Show: All"
      return
    end
    local parts = {}
    if show_filters.high then table.insert(parts, "High") end
    if show_filters.medium then table.insert(parts, "Medium") end
    if show_filters.low then table.insert(parts, "Low") end
    if show_filters.none then table.insert(parts, "No match") end
    items.ShowBtn.Text = "Show: " .. (#parts > 0 and table.concat(parts, ", ") or "(none)")
  end
  update_show_btn_label()

  handlers.ShowBtn = {Clicked = function()
    local changed = self:_show_filter_picker(show_filters)
    if changed then
      local cfg = config.load_config()
      cfg.show_filters = {
        high = show_filters.high, medium = show_filters.medium,
        low = show_filters.low, none = show_filters.none,
      }
      config.save_config(cfg)
      update_show_btn_label()
      self:_populate_tree(tree, show_filters)
    end
  end}

  -- Fusion's tree does NOT reliably fire ItemChanged on checkbox toggles,
  -- so drive selection from ItemClicked and keep ItemChanged as a backup.
  local function apply_toggle(item, forced_state)
    local binding = item and self._item_binding and self._item_binding[item]
    if not binding then
      logger.debug("Tree click: item has no binding (probably a no-match row)")
      return
    end
    local current = "Unchecked"
    pcall(function() current = item.CheckState[0] end)
    local new_state = forced_state
    if new_state == nil then
      new_state = (current == "Checked") and "Unchecked" or "Checked"
    end
    pcall(function() item.CheckState[0] = new_state end)
    logger.debug("Tree toggle: clip=%s cand=%s %s -> %s",
      binding.info_id, binding.cand.path, current, new_state)
    if new_state == "Checked" then
      for other, b in pairs(self._item_binding) do
        if other ~= item and b.info_id == binding.info_id then
          pcall(function() other.CheckState[0] = "Unchecked" end)
        end
      end
      self.selected_candidate[binding.info_id] = binding.cand
    else
      if self.selected_candidate[binding.info_id] == binding.cand then
        self.selected_candidate[binding.info_id] = nil
      end
    end
  end

  handlers.Tree = {
    ItemClicked = function(ev)
      local col = ev and ev.column
      local item = ev and ev.item
      logger.debug("Tree.ItemClicked fired (column=%s)", tostring(col))
      -- Column 0 (checkbox): Fusion toggles the visual state before firing
      -- ItemClicked, so pass the post-toggle state as forced to avoid a
      -- double-toggle while still syncing our selection model.
      if col == 0 then
        local current = "Unchecked"
        pcall(function() current = item.CheckState[0] end)
        apply_toggle(item, current)
        return
      end
      -- Column 2 (match path) acts as a link: open the file in the OS app.
      if col == 2 then
        local binding = item and self._item_binding and self._item_binding[item]
        local path = binding and binding.cand and binding.cand.path
        if path and path ~= "" then
          open_path(path)
          return
        end
      end
      apply_toggle(item, nil)
    end,
    ItemDoubleClicked = function(ev)
      local item = ev and ev.item
      local binding = item and self._item_binding and self._item_binding[item]
      local path = binding and binding.cand and binding.cand.path
      if path and path ~= "" then open_path(path) end
    end,
    ItemChanged = function(ev)
      logger.debug("Tree.ItemChanged fired")
      local item = ev and ev.item
      local binding = item and self._item_binding and self._item_binding[item]
      if not binding then return end
      local checked = false
      pcall(function() checked = (item.CheckState[0] == "Checked") end)
      apply_toggle(item, checked and "Checked" or "Unchecked")
    end,
  }

  handlers.RelinkBtn = {Clicked = function()
    local selections = self:_collect_selections()
    logger.info("RelinkBtn clicked: %d selection(s)", #selections)
    for i, s in ipairs(selections) do
      logger.info("  [%d] -> %s (score=%s)", i, s.new_path, tostring(s.score))
    end
    if #selections == 0 then
      M.show_message("Relink", "Nothing selected. Tick a row in the tree first.")
      return
    end
    local ok, summary = pcall(self.callbacks.on_relink, selections)
    if not ok then
      logger.warn("on_relink raised: %s", tostring(summary))
      M.show_message("Relink failed", tostring(summary), "error")
      return
    end
    logger.info("Relink result: relinked=%d failed=%d skipped=%d",
      summary.relinked or 0, summary.failed or 0, summary.skipped or 0)

    -- Annotate each row per perform_relink's parallel details[i]/selections[i].
    local details = (summary and summary.details) or {}
    local failed_msgs = {}
    for i, sel in ipairs(selections) do
      local d = details[i] or {}
      local item = self._top_item_by_info_id and self._top_item_by_info_id[sel.info_id]
      if item then
        pcall(function()
          if d.success then
            local cur = item.Text[2] or ""
            if not cur:find("^[✓?]") then
              item.Text[2] = "✓ Relinked: " .. cur
            end
            item.TextColor[2] = {R = 0.4, G = 0.9, B = 0.5, A = 1.0}
            item.CheckState[0] = "Unchecked"
            item.ToolTip[2] = "Relinked to: " .. tostring(sel.new_path)
          else
            item.TextColor[2] = {R = 1.0, G = 0.5, B = 0.5, A = 1.0}
            item.ToolTip[2] = "Relink failed: " .. tostring(d.error or "unknown")
            table.insert(failed_msgs, string.format("• %s — %s",
              sel.clip_name or "clip", tostring(d.error or "unknown")))
          end
        end)
      end
      -- Clear selection so a second Relink click doesn't re-relink these.
      if d.success then self.selected_candidate[sel.info_id] = nil end
    end

    local msg = string.format("Relinked: %d  Failed: %d  Skipped: %d",
      summary.relinked or 0, summary.failed or 0, summary.skipped or 0)
    if #failed_msgs > 0 then
      msg = msg .. "\n\nFailures:\n" .. table.concat(failed_msgs, "\n")
    end
    M.show_message("Relink complete", msg,
      (summary.failed or 0) > 0 and "warning" or "info")
  end}

  handlers.HistoryBtn = {Clicked = function()
    self:_show_history_window()
  end}

  handlers.SettingsBtn = {Clicked = function() self:_show_settings_dialog() end}

  for id, events in pairs(handlers) do
    for evname, fn in pairs(events) do
      pcall(function() win.On[id][evname] = fn end)
    end
  end

  win:Show()
  disp:RunLoop()
  win:Hide()
end

function RelinkerWindow:_show_history_window()
  local fu = self._fu
  if not fu then
    local log = RelinkLog.new()
    local entries = log:list_recent(50)
    local lines = {}
    for _, e in ipairs(entries) do
      table.insert(lines, string.format("%s  %s -> %s  (score=%s, %d alts)",
        e.timestamp or "?", basename(e.old_path), basename(e.new_path),
        tostring(e.score), #(e.alternatives or {})))
    end
    M.show_message("Relink history",
      #lines > 0 and table.concat(lines, "\n") or "No relinks recorded yet.")
    return
  end

  local ui = fu.ui
  local disp = fu.disp
  local win_id = "com.jesseb.media_relinker.history"

  local function populate(tree)
    pcall(function() tree:Clear() end)
    local hdr = tree:NewItem()
    hdr.Text[0] = "When"
    hdr.Text[1] = "Clip"
    hdr.Text[2] = "Currently linked to"
    hdr.Text[3] = "Original (offline)"
    hdr.Text[4] = "Score"
    hdr.Text[5] = "Alternatives"
    tree:SetHeaderItem(hdr)

    local log = RelinkLog.new()
    local entries = log:list_recent(200)
    local row_to_entry = {}
    for _, e in ipairs(entries) do
      local it = tree:NewItem()
      it.Text[0] = e.timestamp or ""
      it.Text[1] = e.clip_name or basename(e.old_path)
      it.Text[2] = basename(e.new_path)
      it.Text[3] = basename(e.old_path)
      it.Text[4] = tostring(e.score or "")
      it.Text[5] = tostring(#(e.alternatives or {}))
      tree:AddTopLevelItem(it)
      row_to_entry[it] = e
    end
    return row_to_entry
  end

  local layout = ui:VGroup{
    ui:Label{Text = "Past relinks — select a row, then Revert or Re-pick.", Weight = 0},
    ui:Tree{ID = "HistTree", ColumnCount = 6, SortingEnabled = true},
    ui:HGroup{
      Weight = 0,
      ui:Button{ID = "RevertBtn", Text = "Revert to offline"},
      ui:Button{ID = "RepickBtn", Text = "Re-pick alternative..."},
      ui:HGap(0, 1),
      ui:Button{ID = "RefreshBtn", Text = "Refresh"},
      ui:Button{ID = "CloseHistBtn", Text = "Close"},
    },
  }

  local win = disp:AddWindow({
    ID = win_id,
    WindowTitle = "Relink history",
    Geometry = {260, 240, 900, 500},
  }, layout)

  local items = win:GetItems()
  local tree = items.HistTree
  local row_to_entry = populate(tree)

  local function selected_entry()
    local sel
    pcall(function() sel = tree:CurrentItem() end)
    return sel and row_to_entry[sel]
  end

  local handlers = {}
  handlers[win_id] = {Close = function() disp:ExitLoop() end}
  handlers.CloseHistBtn = {Clicked = function() disp:ExitLoop() end}
  handlers.RefreshBtn = {Clicked = function()
    row_to_entry = populate(tree)
  end}

  handlers.RevertBtn = {Clicked = function()
    local e = selected_entry()
    if not e then
      M.show_message("Revert", "Select a row first.")
      return
    end
    if not self.callbacks.on_revert then return end
    local ok, err = self.callbacks.on_revert(e.id)
    if ok then
      M.show_message("Revert", "Clip reverted to its original (offline) path.")
      row_to_entry = populate(tree)
    else
      M.show_message("Revert failed", tostring(err), "error")
    end
  end}

  handlers.RepickBtn = {Clicked = function()
    local e = selected_entry()
    if not e then
      M.show_message("Re-pick", "Select a row first.")
      return
    end
    local alts = e.alternatives or {}
    if #alts == 0 then
      M.show_message("Re-pick", "No alternatives were captured for this relink.")
      return
    end
    local alt_path = self:_choose_alternative(alts)
    if not alt_path then return end
    if not self.callbacks.on_repick then return end
    local ok, err = self.callbacks.on_repick(e.id, alt_path)
    if ok then
      M.show_message("Re-pick", "Clip relinked to the alternative.")
      row_to_entry = populate(tree)
    else
      M.show_message("Re-pick failed", tostring(err), "error")
    end
  end}

  for id, events in pairs(handlers) do
    for evname, fn in pairs(events) do
      pcall(function() win.On[id][evname] = fn end)
    end
  end

  win:Show()
  disp:RunLoop()
  win:Hide()
end

function RelinkerWindow:_choose_alternative(alts)
  local fu = self._fu
  if not fu then return nil end
  local ui = fu.ui
  local disp = fu.disp
  local win_id = "com.jesseb.media_relinker.altpick"

  local layout = ui:VGroup{
    ui:Label{Text = "Choose an alternative match:", Weight = 0},
    ui:Tree{ID = "AltTree", ColumnCount = 3},
    ui:HGroup{
      Weight = 0,
      ui:HGap(0, 1),
      ui:Button{ID = "PickBtn", Text = "Pick"},
      ui:Button{ID = "CancelBtn", Text = "Cancel"},
    },
  }

  local win = disp:AddWindow({
    ID = win_id,
    WindowTitle = "Pick alternative",
    Geometry = {300, 280, 800, 400},
  }, layout)

  local items = win:GetItems()
  local tree = items.AltTree
  local hdr = tree:NewItem()
  hdr.Text[0] = "Score"; hdr.Text[1] = "File"; hdr.Text[2] = "Reasons"
  tree:SetHeaderItem(hdr)

  local row_to_path = {}
  for _, a in ipairs(alts) do
    local it = tree:NewItem()
    it.Text[0] = tostring(a.score or "")
    it.Text[1] = basename(a.path or "")
    it.Text[2] = table.concat(a.reasons or {}, " | ")
    tree:AddTopLevelItem(it)
    row_to_path[it] = a.path
  end

  local chosen
  local handlers = {}
  handlers[win_id] = {Close = function() disp:ExitLoop() end}
  handlers.CancelBtn = {Clicked = function() disp:ExitLoop() end}
  handlers.PickBtn = {Clicked = function()
    local sel
    pcall(function() sel = tree:CurrentItem() end)
    if sel and row_to_path[sel] then
      chosen = row_to_path[sel]
      disp:ExitLoop()
    end
  end}

  for id, events in pairs(handlers) do
    for evname, fn in pairs(events) do
      pcall(function() win.On[id][evname] = fn end)
    end
  end

  win:Show()
  disp:RunLoop()
  win:Hide()
  return chosen
end


-- Mutates filters in place; returns true on Apply, false on Cancel/close.
function RelinkerWindow:_show_filter_picker(filters)
  local fu = self._fu
  if not fu then return false end
  local ui = fu.ui
  local disp = fu.disp
  local win_id = "com.jesseb.media_relinker.filters"

  local layout = ui:VGroup{
    ui:Label{Text = "Show rows where top match is:", Weight = 0},
    ui:CheckBox{ID = "F_High",   Text = "High (auto-match)",  Checked = filters.high},
    ui:CheckBox{ID = "F_Medium", Text = "Medium (strong)",    Checked = filters.medium},
    ui:CheckBox{ID = "F_Low",    Text = "Low (weak)",         Checked = filters.low},
    ui:CheckBox{ID = "F_None",   Text = "No match",           Checked = filters.none},
    ui:HGroup{Weight = 0,
      ui:HGap(0, 1),
      ui:Button{ID = "ApplyBtn",  Text = "Apply"},
      ui:Button{ID = "CancelBtn", Text = "Cancel"},
    },
  }

  local win = disp:AddWindow({
    ID = win_id,
    WindowTitle = "Filter",
    Geometry = {320, 320, 320, 200},
  }, layout)

  local items = win:GetItems()
  local applied = false

  local handlers = {
    [win_id]    = {Close   = function() disp:ExitLoop() end},
    CancelBtn   = {Clicked = function() disp:ExitLoop() end},
    ApplyBtn    = {Clicked = function()
      filters.high   = items.F_High.Checked and true or false
      filters.medium = items.F_Medium.Checked and true or false
      filters.low    = items.F_Low.Checked and true or false
      filters.none   = items.F_None.Checked and true or false
      applied = true
      disp:ExitLoop()
    end},
  }
  for id, events in pairs(handlers) do
    for ev, fn in pairs(events) do
      pcall(function() win.On[id][ev] = fn end)
    end
  end
  win:Show(); disp:RunLoop(); win:Hide()
  return applied
end

function RelinkerWindow:_show_settings_dialog()
  local fu = self._fu
  if not fu then return end
  local cfg = config.load_config()
  local ui = fu.ui
  local disp = fu.disp

  local weight_keys = {}
  for k in pairs(cfg.weights or {}) do table.insert(weight_keys, k) end
  table.sort(weight_keys)

  local rows = {
    ui:Label{Text = "Thresholds", Weight = 0},
    ui:HGroup{Weight = 0,
      ui:Label{Text = "High ≥", Weight = 0},
      ui:LineEdit{ID = "ThreshAuto", Text = tostring(cfg.auto_match_threshold), Weight = 0},
      ui:Label{Text = "Medium ≥", Weight = 0},
      ui:LineEdit{ID = "ThreshStrong", Text = tostring(cfg.strong_threshold), Weight = 0},
      ui:Label{Text = "Low ≥", Weight = 0},
      ui:LineEdit{ID = "ThreshWeak", Text = tostring(cfg.weak_threshold), Weight = 0},
    },
    ui:Label{Text = "Weights", Weight = 0},
  }
  for _, k in ipairs(weight_keys) do
    table.insert(rows, ui:HGroup{Weight = 0,
      ui:Label{Text = k, Weight = 1},
      ui:LineEdit{ID = "W_" .. k, Text = tostring(cfg.weights[k] or 0), Weight = 0},
    })
  end
  table.insert(rows, ui:HGroup{Weight = 0,
    ui:Button{ID = "SaveBtn", Text = "Save"},
    ui:Button{ID = "CancelBtn", Text = "Cancel"},
  })

  local layout = ui:VGroup(rows)
  local dlg = disp:AddWindow({
    ID = "MediaRelinkerSettings",
    WindowTitle = "Settings",
    Geometry = {300, 300, 500, 600},
  }, layout)
  local items = dlg:GetItems()

  dlg.On.MediaRelinkerSettings.Close = function() disp:ExitLoop() end
  dlg.On.CancelBtn.Clicked = function() disp:ExitLoop() end
  dlg.On.SaveBtn.Clicked = function()
    local new_cfg = config.deep_copy(cfg)
    new_cfg.auto_match_threshold = tonumber(items.ThreshAuto.Text) or new_cfg.auto_match_threshold
    new_cfg.strong_threshold = tonumber(items.ThreshStrong.Text) or new_cfg.strong_threshold
    new_cfg.weak_threshold = tonumber(items.ThreshWeak.Text) or new_cfg.weak_threshold
    new_cfg.weights = new_cfg.weights or {}
    for _, k in ipairs(weight_keys) do
      local v = tonumber(items["W_" .. k].Text)
      if v then new_cfg.weights[k] = v end
    end
    config.save_config(new_cfg)
    disp:ExitLoop()
  end

  dlg:Show()
  disp:RunLoop()
  dlg:Hide()
end

function RelinkerWindow:_run_console()
  io.stderr:write("[media_relinker] No Fusion UI available. Use the CLI interface.\n")
  io.stderr:write(string.format("Offline clips: %d\n", #self.clips))
  for _, info in ipairs(self.clips) do
    io.stderr:write(string.format("  - %s\n", info.name or "?"))
  end
end

M.RelinkerWindow = RelinkerWindow
return M
