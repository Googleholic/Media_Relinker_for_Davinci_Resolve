local config = require("media_relinker.config")
local fs = require("media_relinker.fs")
local json = require("media_relinker.json")
local logger = require("media_relinker.logger").get_logger("media_relinker.cache")

logger.info("Cache init: lfs available = %s", tostring(fs.has_lfs))

local M = {}
M.__index = M

-- Bump when the metadata shape from exiftool.normalise changes so older entries invalidate.
M.SCHEMA = 2

local function stat(path)
  local mt = fs.mtime(path) or 0
  local sz = fs.size(path)
  if not sz then return nil end
  return mt, sz
end

function M.new(cache_path)
  local self = setmetatable({}, M)
  self.path = cache_path or config.path_join(config.get_config_dir(), "cache.json")
  self.entries = {}
  self.dirty = false
  self.hits = 0
  self.misses = 0
  self:_load()
  return self
end

function M:_load()
  local f = io.open(self.path, "r")
  if not f then return end
  local content = f:read("*a")
  f:close()
  if not content or content == "" then return end
  local ok, data = pcall(json.decode, content)
  if ok and type(data) == "table" then
    self.entries = data
  else
    logger.warn("Could not parse cache JSON; starting empty")
    self.entries = {}
  end
end

function M:get(abspath)
  local entry = self.entries[abspath]
  if not entry then
    self.misses = self.misses + 1
    return nil
  end
  local mt, sz = stat(abspath)
  if not mt then
    self.misses = self.misses + 1
    return nil
  end
  if sz ~= entry.size or math.abs(mt - (entry.mtime or 0)) > 1 then
    self.misses = self.misses + 1
    return nil
  end
  if (entry.schema or 0) < M.SCHEMA then
    self.misses = self.misses + 1
    return nil
  end
  self.hits = self.hits + 1
  return entry.metadata
end

function M:put(abspath, metadata)
  local mt, sz = stat(abspath)
  if not mt then return end
  self.entries[abspath] = {
    mtime = mt,
    size = sz,
    metadata = metadata,
    cached_at = os.time(),
    schema = M.SCHEMA,
  }
  self.dirty = true
end

function M:clear()
  self.entries = {}
  self.dirty = true
end

function M:stats()
  local total = 0
  for _ in pairs(self.entries) do total = total + 1 end
  return {hits = self.hits, misses = self.misses, total_rows = total, path = self.path}
end

function M:flush()
  if not self.dirty then return true end
  local tmp = self.path .. ".tmp"
  local f, ferr = io.open(tmp, "w")
  if not f then
    logger.warn("flush: cannot open tmp %s: %s", tmp, tostring(ferr))
    return false
  end
  f:write(json.encode(self.entries))
  f:close()
  os.remove(self.path)
  local ok, rerr = os.rename(tmp, self.path)
  if not ok then
    logger.warn("flush: rename %s -> %s failed (%s); falling back to copy",
      tmp, self.path, tostring(rerr))
    local r = io.open(tmp, "r")
    if not r then
      logger.warn("flush: tmp file vanished after rename failure")
      return false
    end
    local content = r:read("*a")
    r:close()
    local w, werr = io.open(self.path, "w")
    if not w then
      logger.warn("flush: fallback write to %s failed: %s", self.path, tostring(werr))
      return false
    end
    w:write(content); w:close()
    os.remove(tmp)
  end
  self.dirty = false
  return true
end

function M:close()
  self:flush()
end

return M
