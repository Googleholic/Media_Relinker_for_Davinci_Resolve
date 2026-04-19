local M = {}

local function round(x) return math.floor(x + 0.5) end

function M.nominal_fps(fps)
  if not fps or fps <= 0 then return 0 end
  return round(fps)
end

function M.is_drop_frame_fps(fps)
  if not fps then return false end
  local frac = fps - math.floor(fps)
  return frac > 0.1 and frac < 0.99 and (round(fps) == 30 or round(fps) == 60)
end

function M.parse(tc, fps)
  if type(tc) ~= "string" or not fps or fps <= 0 then return nil end
  local s = tc:match("^%s*(.-)%s*$")
  if not s or s == "" then return nil end
  local hh, mm, ss, sep, ff = s:match("^(%d+):(%d+):(%d+)([:;])(%d+)$")
  if not hh then return nil end
  hh, mm, ss, ff = tonumber(hh), tonumber(mm), tonumber(ss), tonumber(ff)
  local drop = (sep == ";")
  local nom = round(fps)
  if drop and (nom == 30 or nom == 60) then
    local drop_frames = (nom == 30) and 2 or 4
    local fpm = nom * 60 - drop_frames
    local fp10 = nom * 60 * 10 - drop_frames * 9
    local total_min = 60 * hh + mm
    return fp10 * math.floor(total_min / 10)
      + fpm * (total_min % 10)
      + nom * ss
      + ff
  end
  return round(((hh * 3600) + (mm * 60) + ss) * fps) + ff
end

function M.format(frames, fps, drop)
  if not frames or not fps or fps <= 0 then return nil end
  local nom = round(fps)
  if drop and (nom == 30 or nom == 60) then
    local drop_frames = (nom == 30) and 2 or 4
    local fp10 = nom * 60 * 10 - drop_frames * 9
    local fpm = nom * 60 - drop_frames
    local d = math.floor(frames / fp10)
    local m = frames % fp10
    local min10, mrem
    if m > drop_frames then
      min10 = math.floor((m - drop_frames) / fpm) + 1
      mrem = (m - drop_frames) % fpm + drop_frames
    else
      min10 = 0
      mrem = m
    end
    local total_min = 10 * d + min10
    local fnum = frames + drop_frames * 9 * d + drop_frames * min10 - drop_frames * (min10 > 0 and 1 or 0)
    local hh = math.floor(total_min / 60) % 24
    local mm = total_min % 60
    local ss = math.floor(mrem / nom) % 60
    local ff = mrem % nom
    return string.format("%02d:%02d:%02d;%02d", hh, mm, ss, ff)
  end
  local n = round(frames)
  local total_sec = math.floor(n / nom)
  local ff = n % nom
  local ss = total_sec % 60
  local mm = math.floor(total_sec / 60) % 60
  local hh = math.floor(total_sec / 3600) % 24
  return string.format("%02d:%02d:%02d:%02d", hh, mm, ss, ff)
end

function M.duration_to_frames(value, fps)
  if value == nil or not fps or fps <= 0 then return nil end
  local t = type(value)
  if t == "number" then
    if value == math.floor(value) and value > 10 then
      return math.floor(value)
    end
    return round(value * fps)
  end
  if t == "string" then
    local s = value:match("^%s*(.-)%s*$")
    if s == "" then return nil end
    if s:match("^(%d+):(%d+):(%d+)[:;](%d+)$") then
      return M.parse(s, fps)
    end
    local n = tonumber(s)
    if n then
      if s:find("%.") then return round(n * fps) end
      return math.floor(n)
    end
    return nil
  end
  return nil
end

return M
