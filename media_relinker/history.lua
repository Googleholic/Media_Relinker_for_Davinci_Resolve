local config = require("media_relinker.config")
local json = require("media_relinker.json")
local logger = require("media_relinker.logger").get_logger("media_relinker.history")

local M = {}
M.__index = M

function M.new(path)
  local self = setmetatable({}, M)
  self.path = path or config.path_join(config.get_config_dir(), "history.json")
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
  if not f then return false end
  f:write(json.encode(self.entries))
  f:close()
  return true
end

function M:record(entry)
  entry = entry or {}
  entry.timestamp = entry.timestamp or os.date("!%Y-%m-%dT%H:%M:%SZ")
  table.insert(self.entries, 1, entry)
  while #self.entries > 500 do table.remove(self.entries) end
  self:_save()
  logger.info("Recorded history entry: %s clips, %d relinks",
    entry.clip_count or 0, entry.relinks_performed or 0)
  return entry
end

function M:list_sessions(limit)
  limit = limit or 50
  local out = {}
  for i = 1, math.min(limit, #self.entries) do
    out[i] = self.entries[i]
  end
  return out
end

return M
