-- Media Relinker — DaVinci Resolve Scripts menu entry point (Lua).
-- Copied into Resolve's Scripts/Comp directory by install.lua / install.py.
-- Invoked via Workspace -> Scripts -> Media Relinker.

local function is_windows()
  return package.config:sub(1, 1) == "\\"
end

local function home_dir()
  if is_windows() then
    local up = os.getenv("USERPROFILE")
    if up and up ~= "" then return up end
    return (os.getenv("HOMEDRIVE") or "") .. (os.getenv("HOMEPATH") or "")
  end
  return os.getenv("HOME") or "."
end

local function path_join(a, b)
  if a == "" or a == nil then return b end
  local sep = is_windows() and "\\" or "/"
  local last = a:sub(-1)
  if last == "/" or last == "\\" then return a .. b end
  return a .. sep .. b
end

local function file_exists(p)
  if not p or p == "" then return false end
  local f = io.open(p, "r")
  if f then f:close() return true end
  return false
end

local function candidate_roots()
  local roots = {}
  table.insert(roots, path_join(home_dir(), ".media_relinker/plugin"))
  local env = os.getenv("MEDIA_RELINKER_HOME")
  if env and env ~= "" then
    table.insert(roots, path_join(env, "plugin"))
    table.insert(roots, env)
  end
  local src = debug.getinfo(1, "S").source
  if src and src:sub(1, 1) == "@" then
    local here = src:sub(2):match("^(.*)[/\\][^/\\]+$")
    if here then
      table.insert(roots, here)
      local up1 = here:match("^(.*)[/\\][^/\\]+$")
      if up1 then table.insert(roots, up1) end
      local up2 = up1 and up1:match("^(.*)[/\\][^/\\]+$") or nil
      if up2 then table.insert(roots, up2) end
    end
  end
  local appdata = os.getenv("APPDATA")
  if appdata and appdata ~= "" then
    table.insert(roots, path_join(appdata,
      "Blackmagic Design\\DaVinci Resolve\\Support\\Fusion\\Scripts\\Comp"))
  end
  return roots
end

local function locate_package()
  for _, root in ipairs(candidate_roots()) do
    local main_lua = path_join(path_join(root, "media_relinker"), "main.lua")
    if file_exists(main_lua) then return root end
  end
  return nil
end

local function write_crash_log(msg)
  local log_path = path_join(home_dir(), ".media_relinker") .. (is_windows() and "\\" or "/") .. "launcher_crash.log"
  local f = io.open(log_path, "a")
  if f then
    f:write(os.date("[%Y-%m-%d %H:%M:%S] ") .. msg .. "\n")
    f:close()
    return log_path
  end
  return nil
end

local function show_error(msg)
  print("[Media Relinker] " .. msg)
  local path = write_crash_log(msg)
  if path then print("[Media Relinker] Crash log: " .. path) end
  local ok_bmd, bmd_mod = pcall(function() return bmd end)
  if ok_bmd and bmd_mod and bmd_mod.AskUser then
    pcall(function()
      bmd_mod.AskUser("Media Relinker",
        {["1"] = {[1] = "Error", [2] = "Text", Default = msg}})
    end)
  end
end

local function main()
  local root = locate_package()
  if not root then
    show_error("Could not locate the `media_relinker` Lua package.\n\n" ..
      "Checked:\n  - ~/.media_relinker/plugin/\n  - $MEDIA_RELINKER_HOME\n  - script siblings\n\n" ..
      "Reinstall the plugin or set MEDIA_RELINKER_HOME.")
    return 1
  end

  local sep = is_windows() and "\\" or "/"
  package.path = root .. sep .. "?.lua;" ..
                 root .. sep .. "?" .. sep .. "init.lua;" ..
                 package.path

  -- Bundle LuaFileSystem (lfs.dll / lfs.so) if present under bin/<os>/.
  -- When lfs loads, scanner/cache/fs all go shell-free → zero cmd flashes.
  local bin_sub = is_windows() and "windows" or (package.config:sub(1,1) == "/" and "linux" or "macos")
  local native_ext = is_windows() and "dll" or "so"
  local native_dir = root .. sep .. "bin" .. sep .. bin_sub
  package.cpath = native_dir .. sep .. "?." .. native_ext .. ";" .. package.cpath
  if is_windows() and os.getenv("PATH") then
    -- Ensure the OS loader can find any dependent DLLs in the same folder.
    local cur = os.getenv("PATH") or ""
    if not cur:find(native_dir, 1, true) then
      -- Note: this only affects the current process env, which is enough.
      local ok_setenv = pcall(function()
        if os.setenv then os.setenv("PATH", native_dir .. ";" .. cur) end
      end)
      if not ok_setenv then
        -- Fallback via _putenv if setenv missing (most Windows Lua has it).
      end
    end
  end
  -- Try lfs silently. If unavailable, scanner falls back to bmd.readdir
  -- (also zero-flash), so absence of lfs is not a problem worth surfacing.
  pcall(require, "lfs")

  -- Dev-only: Resolve's Fusion Lua interpreter persists package.loaded across
  -- script invocations, so edits to any media_relinker submodule are ignored
  -- until Resolve restarts. Flushing our namespace before require() forces a
  -- fresh load from disk every run. Remove this loop for production if you
  -- want to preserve the (small) startup caching benefit.
  for mod in pairs(package.loaded) do
    if type(mod) == "string" and mod:match("^media_relinker") then
      package.loaded[mod] = nil
    end
  end

  local ok, main_mod = pcall(require, "media_relinker.main")
  if not ok then
    show_error("Failed to load media_relinker.main:\n" .. tostring(main_mod))
    return 1
  end
  local ok2, err = pcall(main_mod.run)
  if not ok2 then
    show_error("Media Relinker crashed:\n" .. tostring(err))
    return 1
  end
  return err or 0
end

return main()
