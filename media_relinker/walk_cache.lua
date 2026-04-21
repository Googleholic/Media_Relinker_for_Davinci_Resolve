-- Persistent per-root file-list cache. Lets repeat scans of the same folder
-- skip the directory walk entirely when the folder hasn't changed.
--
-- Keyed by (root, recursive) and stored alongside the metadata cache in
-- $HOME/.media_relinker/walk_cache.json, so it's global across projects.

local config = require("media_relinker.config")
local fs = require("media_relinker.fs")
local json = require("media_relinker.json")
local logger = require("media_relinker.logger").get_logger("media_relinker.walk_cache")

local M = {}
M.__index = M

M.SCHEMA = 1

local function make_key(root, recursive)
  return (recursive and "R|" or "N|") .. tostring(root)
end

local function sorted_ext_list(exts)
  local out = {}
  for e in pairs(exts or {}) do out[#out + 1] = e end
  table.sort(out)
  return out
end

local function ext_fingerprint(exts)
  return table.concat(sorted_ext_list(exts), ",")
end

function M.new(cache_path)
  local self = setmetatable({}, M)
  self.path = cache_path or config.path_join(config.get_config_dir(), "walk_cache.json")
  self.entries = {}
  self.dirty = false
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
  if ok and type(data) == "table" and type(data.entries) == "table" then
    self.entries = data.entries
  end
end

-- Returns entry if usable for (root, recursive, extensions) — nil if missing
-- or stale. Staleness: schema mismatch, extensions differ, or (LFS only) the
-- root's mtime changed since the cache was written. Without LFS we trust the
-- cache and rely on the user's "Rescan from disk" / "Clear cache" controls.
function M:get(root, recursive, extensions)
  local e = self.entries[make_key(root, recursive)]
  if not e then return nil end
  if (e.schema or 0) ~= M.SCHEMA then return nil end
  if e.extensions_fp ~= ext_fingerprint(extensions) then
    logger.info("Walk cache: extensions changed for %s — invalidating", root)
    return nil
  end
  if fs.has_lfs then
    local m = fs.mtime(root)
    if m and e.root_mtime and math.abs(m - e.root_mtime) > 1 then
      logger.info("Walk cache: root mtime changed for %s (%s -> %s) — invalidating",
        root, tostring(e.root_mtime), tostring(m))
      return nil
    end
  end
  return e
end

function M:put(root, recursive, extensions, files)
  local m = fs.has_lfs and fs.mtime(root) or nil
  self.entries[make_key(root, recursive)] = {
    schema = M.SCHEMA,
    root = root,
    recursive = recursive and true or false,
    extensions_fp = ext_fingerprint(extensions),
    root_mtime = m,
    scanned_at = os.time(),
    files = files,
  }
  self.dirty = true
end

function M:drop(root, recursive)
  local key = make_key(root, recursive)
  if self.entries[key] then
    self.entries[key] = nil
    self.dirty = true
  end
end

function M:clear()
  self.entries = {}
  self.dirty = true
end

-- List of unique root paths across all recursive/non-recursive entries.
function M:roots()
  local seen, out = {}, {}
  for _, e in pairs(self.entries) do
    if e.root and not seen[e.root] then
      seen[e.root] = true
      out[#out + 1] = e.root
    end
  end
  table.sort(out)
  return out
end

function M:flush()
  if not self.dirty then return true end
  local tmp = self.path .. ".tmp"
  local f, ferr = io.open(tmp, "w")
  if not f then
    logger.warn("flush: cannot open tmp %s: %s", tmp, tostring(ferr))
    return false
  end
  f:write(json.encode({schema = M.SCHEMA, entries = self.entries}))
  f:close()
  os.remove(self.path)
  local ok, rerr = os.rename(tmp, self.path)
  if not ok then
    logger.warn("flush: rename failed (%s); copy fallback", tostring(rerr))
    local r = io.open(tmp, "r")
    if not r then return false end
    local content = r:read("*a"); r:close()
    local w = io.open(self.path, "w")
    if not w then return false end
    w:write(content); w:close()
    os.remove(tmp)
  end
  self.dirty = false
  return true
end

return M
