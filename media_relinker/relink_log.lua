local config = require("media_relinker.config")
local json = require("media_relinker.json")
local logger = require("media_relinker.logger").get_logger("media_relinker.relink_log")

local M = {}
M.__index = M

function M.new(path)
  local self = setmetatable({}, M)
  self.path = path or config.path_join(config.get_config_dir(), "relink_log.json")
  self.entries = {}
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
  if ok and type(data) == "table" then self.entries = data end
end

function M:_save()
  local f = io.open(self.path, "w")
  if not f then
    logger.warn("Could not open %s for write", self.path)
    return false
  end
  f:write(json.encode(self.entries))
  f:close()
  return true
end

local function new_id()
  return string.format("%d-%d", os.time(), math.random(100000, 999999))
end

function M:append(entry)
  entry = entry or {}
  entry.id = entry.id or new_id()
  entry.timestamp = entry.timestamp or os.date("!%Y-%m-%dT%H:%M:%SZ")
  table.insert(self.entries, entry)
  while #self.entries > 2000 do table.remove(self.entries, 1) end
  self:_save()
  return entry
end

function M:list_recent(limit)
  limit = limit or 100
  local out = {}
  local n = #self.entries
  for i = 0, math.min(limit, n) - 1 do
    out[#out + 1] = self.entries[n - i]
  end
  return out
end

function M:find(id)
  for i, e in ipairs(self.entries) do
    if e.id == id then return e, i end
  end
  return nil
end

function M:remove(id)
  local _, idx = self:find(id)
  if idx then
    table.remove(self.entries, idx)
    self:_save()
    return true
  end
  return false
end

function M:update(id, mutator)
  local entry, idx = self:find(id)
  if not entry then return false end
  mutator(entry)
  self.entries[idx] = entry
  self:_save()
  return true
end

return M
