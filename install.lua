-- Standalone Lua installer. Mirrors install.py for users with a Lua runtime.
-- Run with:  lua install.lua  [--dry-run|--uninstall|--skip-exiftool|-y]

local function is_windows()
  return package.config:sub(1, 1) == "\\"
end

local function sep() return is_windows() and "\\" or "/" end

local function home()
  if is_windows() then
    return os.getenv("USERPROFILE") or
      ((os.getenv("HOMEDRIVE") or "") .. (os.getenv("HOMEPATH") or ""))
  end
  return os.getenv("HOME") or "."
end

local function path_join(...)
  local parts = {...}
  local out
  for i, p in ipairs(parts) do
    if not p or p == "" then
      -- skip
    elseif not out then
      out = p
    else
      local last = out:sub(-1)
      if last == "/" or last == "\\" then out = out .. p else out = out .. sep() .. p end
    end
  end
  return out or ""
end

local function exists(p)
  if not p then return false end
  if is_windows() then
    local ok = os.execute('if exist "' .. p:gsub("/", "\\") .. '" (exit 0) else (exit 1)')
    return ok == true or ok == 0
  end
  local ok = os.execute('[ -e "' .. p .. '" ]')
  return ok == true or ok == 0
end

local function mkdir_p(p)
  if exists(p) then return end
  if is_windows() then
    os.execute('mkdir "' .. p:gsub("/", "\\") .. '" >nul 2>&1')
  else
    os.execute('mkdir -p "' .. p .. '" >/dev/null 2>&1')
  end
end

local function rm_rf(p)
  if not exists(p) then return end
  if is_windows() then
    os.execute('rmdir /s /q "' .. p:gsub("/", "\\") .. '" >nul 2>&1')
    os.execute('del /q "' .. p:gsub("/", "\\") .. '" >nul 2>&1')
  else
    os.execute('rm -rf "' .. p .. '"')
  end
end

local function cp_r(src, dst)
  mkdir_p(dst)
  if is_windows() then
    os.execute(string.format('xcopy /E /I /Y /Q "%s" "%s" >nul', src:gsub("/", "\\"), dst:gsub("/", "\\")))
  else
    os.execute(string.format('cp -R "%s/." "%s/"', src, dst))
  end
end

local function cp_file(src, dst)
  local parent = dst:match("^(.*)[/\\][^/\\]+$")
  if parent then mkdir_p(parent) end
  if is_windows() then
    os.execute(string.format('copy /Y "%s" "%s" >nul', src:gsub("/", "\\"), dst:gsub("/", "\\")))
  else
    os.execute(string.format('cp "%s" "%s"', src, dst))
  end
end

local function scripts_comp_dir()
  if is_windows() then
    local appdata = os.getenv("APPDATA") or error("APPDATA not set")
    return path_join(appdata, "Blackmagic Design", "DaVinci Resolve",
                     "Support", "Fusion", "Scripts", "Comp")
  end
  local os_name = io.popen("uname -s"):read("*l") or "Linux"
  if os_name == "Darwin" then
    return "/Library/Application Support/Blackmagic Design/DaVinci Resolve/Fusion/Scripts/Comp"
  end
  return "/opt/resolve/Fusion/Scripts/Comp"
end

local function project_root()
  local src = debug.getinfo(1, "S").source
  if src:sub(1, 1) == "@" then
    return src:sub(2):match("^(.*)[/\\][^/\\]+$") or "."
  end
  return "."
end

local function parse_args(argv)
  local out = {}
  for _, a in ipairs(argv or {}) do
    if a == "--dry-run" then out.dry_run = true
    elseif a == "--uninstall" then out.uninstall = true
    elseif a == "--skip-exiftool" then out.skip_exiftool = true
    elseif a == "-y" or a == "--yes" then out.yes = true
    end
  end
  return out
end

local function do_install(root, dry)
  local scripts = scripts_comp_dir()
  local plugin_home = path_join(home(), ".media_relinker", "plugin")
  print("Launcher:       " .. scripts)
  print("Plugin payload: " .. plugin_home)

  local src_pkg = path_join(root, "media_relinker")
  local src_vendor = path_join(root, "vendor")
  local src_entry = path_join(root, "Scripts", "Comp", "Media Relinker.lua")
  for _, s in ipairs({src_pkg, src_vendor, src_entry}) do
    if not exists(s) then print("ERROR: missing " .. s); return 2 end
  end

  if dry then
    print("[dry-run] would copy " .. src_pkg .. " -> " .. path_join(plugin_home, "media_relinker"))
    print("[dry-run] would copy " .. src_vendor .. " -> " .. path_join(plugin_home, "vendor"))
    print("[dry-run] would copy " .. src_entry .. " -> " .. path_join(scripts, "Media Relinker.lua"))
    return 0
  end

  mkdir_p(scripts); mkdir_p(plugin_home)
  rm_rf(path_join(plugin_home, "media_relinker"))
  rm_rf(path_join(plugin_home, "vendor"))
  cp_r(src_pkg, path_join(plugin_home, "media_relinker"))
  cp_r(src_vendor, path_join(plugin_home, "vendor"))
  cp_file(src_entry, path_join(scripts, "Media Relinker.lua"))
  print("Install complete. Restart Resolve and run Workspace -> Scripts -> Media Relinker.")
  print("Note: ExifTool auto-download is not handled by this Lua installer — use install.py for that.")
  return 0
end

local function do_uninstall(dry)
  local scripts = scripts_comp_dir()
  local plugin_home = path_join(home(), ".media_relinker", "plugin")
  local entry = path_join(scripts, "Media Relinker.lua")
  print("Removing: " .. entry)
  print("Removing: " .. plugin_home)
  if dry then print("[dry-run]") return 0 end
  rm_rf(entry); rm_rf(plugin_home)
  print("Uninstall complete.")
  return 0
end

local args = parse_args(arg or {})
local root = project_root()
if args.uninstall then os.exit(do_uninstall(args.dry_run)) end
os.exit(do_install(root, args.dry_run))
