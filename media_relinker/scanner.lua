local config = require("media_relinker.config")
local fs = require("media_relinker.fs")
local logger = require("media_relinker.logger").get_logger("media_relinker.scanner")

logger.info("Scanner init: lfs available = %s", tostring(fs.has_lfs))
fs.probe_bmd_fs()

local M = {}

function M.default_extensions()
  local cfg = config.load_config()
  local out = {}
  local groups = cfg.extensions or {}
  for _, group in ipairs({"video", "image", "audio"}) do
    for _, e in ipairs(groups[group] or {}) do
      if e and e ~= "" then
        local ext = e:lower()
        if ext:sub(1, 1) ~= "." then ext = "." .. ext end
        out[ext] = true
      end
    end
  end
  return out
end

local function split_ext(name)
  local stem, ext = name:match("^(.*)(%.[^%.]+)$")
  if not stem then return name, "" end
  return stem, ext
end

-- Shell-fallback listing used only when neither lfs nor bmd.readdir is available.
local function batched_dir_windows(root, recursive)
  local flag = recursive and "/s " or ""
  local cmd = string.format('dir /b /a:-d %s"%s" 2>nul',
    flag, root:gsub("/", "\\"))
  logger.info("Executing batched directory listing: %s", cmd)
  local p = io.popen(cmd, "r")
  if not p then
    logger.error("io.popen failed for directory listing")
    return {}
  end
  local out = {}
  local n = 0
  for line in p:lines() do
    if line and line ~= "" then
      -- /s yields absolute paths; /b without /s yields relative.
      if recursive then
        table.insert(out, line)
      else
        table.insert(out, (root:gsub("[\\/]+$", "")) .. "\\" .. line)
      end
      n = n + 1
    end
  end
  p:close()
  logger.info("Batched dir returned %d raw entries under %s", n, root)
  return out
end

local function batched_dir_posix(root, recursive)
  local cmd
  if recursive then
    cmd = string.format('find "%s" -type f 2>/dev/null', root)
  else
    cmd = string.format('ls -A -1 "%s" 2>/dev/null', root)
  end
  logger.info("Executing batched directory listing: %s", cmd)
  local p = io.popen(cmd, "r")
  if not p then return {} end
  local out = {}
  for line in p:lines() do
    if line and line ~= "" then
      if recursive then table.insert(out, line)
      else table.insert(out, root .. "/" .. line) end
    end
  end
  p:close()
  return out
end

function M.walk_media(root, recursive, extensions)
  if not root or root == "" then error("Scan root is empty") end
  if not config.path_exists(root) then error("Scan root does not exist: " .. root) end
  if not config.is_dir(root) then error("Scan root is not a directory: " .. root) end

  local exts = {}
  if extensions then
    for e in pairs(extensions) do
      local ext = e:lower()
      if ext:sub(1, 1) ~= "." then ext = "." .. ext end
      exts[ext] = true
    end
  else
    exts = M.default_extensions()
  end

  local ext_list = {}
  for e in pairs(exts) do table.insert(ext_list, e) end
  logger.info("walk_media start: root=%s recursive=%s extensions=[%s]",
    root, tostring(recursive), table.concat(ext_list, ", "))

  local results = {}
  if fs.has_native_listdir() then
    logger.info("Using native listdir backend")
    local stack = {root}
    while #stack > 0 do
      local dir = table.remove(stack)
      local entries, err = fs.listdir(dir)
      if not entries then
        logger.warn("listdir failed for %s: %s", dir, tostring(err))
      else
        for _, name in ipairs(entries) do
          if name:sub(1, 1) ~= "." then
            local full = config.path_join(dir, name)
            if config.is_dir(full) then
              if recursive then table.insert(stack, full) end
            else
              local _, ext = split_ext(name)
              if exts[ext:lower()] then
                table.insert(results, full)
              end
            end
          end
        end
      end
    end
  else
    local raw = config.is_windows()
      and batched_dir_windows(root, recursive)
      or batched_dir_posix(root, recursive)
    local skipped = 0
    for _, full in ipairs(raw) do
      local name = full:match("([^/\\]+)$") or full
      local _, ext = split_ext(name)
      if exts[ext:lower()] then
        table.insert(results, full)
      else
        skipped = skipped + 1
      end
    end
    logger.info("Filtered %d entries by extension (kept %d, skipped %d)",
      #raw, #results, skipped)
  end

  logger.info("Walk phase: found %d files under %s", #results, root)
  for i, p in ipairs(results) do
    if i <= 25 then logger.info("  [%03d] %s", i, p) end
  end
  if #results > 25 then
    logger.info("  ... (%d more files not listed individually)", #results - 25)
  end
  return results
end

return M
