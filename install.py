#!/usr/bin/env python3
"""Media Relinker (Lua port) installer.

Copies the Lua plugin package and entry-point script to DaVinci Resolve's
Scripts/Comp directory. Downloads ExifTool on Windows. Mirrors the CLI of
the Python installer so existing docs keep working.

Usage:
    python install.py              # install (prompts on overwrite)
    python install.py --dry-run    # show what would happen
    python install.py --uninstall  # remove an existing install
    python install.py -y           # assume yes to all prompts
    python install.py --skip-exiftool   # don't download ExifTool
"""
from __future__ import annotations

import argparse
import os
import shutil
import sys
import tempfile
import urllib.request
import zipfile
from pathlib import Path

PACKAGE_NAME = "media_relinker"
VENDOR_NAME = "vendor"
ENTRY_SCRIPT_REL = Path("Scripts") / "Comp" / "Media Relinker.lua"
ENTRY_SCRIPT_BASENAME = "Media Relinker.lua"

EXIFTOOL_VERSION_URL = "https://exiftool.org/ver.txt"
EXIFTOOL_WIN_URL_TEMPLATE = "https://exiftool.org/exiftool-{ver}_64.zip"

_ASSUME_YES = False


def _os() -> str:
    p = sys.platform
    if p.startswith("win") or p in ("cygwin", "msys"):
        return "Windows"
    if p == "darwin":
        return "Darwin"
    if p.startswith("linux"):
        return "Linux"
    return p


def resolve_scripts_comp_dir() -> Path:
    system = _os()
    if system == "Windows":
        appdata = os.environ.get("APPDATA")
        if not appdata:
            raise RuntimeError("APPDATA environment variable is not set.")
        return (Path(appdata) / "Blackmagic Design" / "DaVinci Resolve"
                / "Support" / "Fusion" / "Scripts" / "Comp")
    if system == "Darwin":
        return Path("/Library/Application Support/Blackmagic Design/DaVinci Resolve/Fusion/Scripts/Comp")
    if system == "Linux":
        return Path("/opt/resolve/Fusion/Scripts/Comp")
    raise RuntimeError(f"Unsupported OS: {system}")


def prompt_yes_no(question: str, default_no: bool = True) -> bool:
    if _ASSUME_YES:
        return True
    suffix = " [y/N] " if default_no else " [Y/n] "
    sys.stdout.write(question + suffix)
    sys.stdout.flush()
    try:
        ans = sys.stdin.readline().strip().lower()
    except EOFError:
        return False
    if not ans:
        return not default_no
    return ans in ("y", "yes")


def copy_tree(src: Path, dst: Path, dry_run: bool) -> None:
    if dry_run:
        print(f"  [dry-run] copy tree {src} -> {dst}")
        return
    if dst.exists():
        shutil.rmtree(dst)
    shutil.copytree(src, dst)


def copy_file(src: Path, dst: Path, dry_run: bool) -> None:
    if dry_run:
        print(f"  [dry-run] copy file {src} -> {dst}")
        return
    dst.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(src, dst)


def remove_path(path: Path, dry_run: bool) -> None:
    if not path.exists():
        return
    if dry_run:
        print(f"  [dry-run] remove {path}")
        return
    if path.is_dir():
        shutil.rmtree(path)
    else:
        path.unlink()


def find_exiftool(project_root: Path) -> tuple[bool, str]:
    exe = "exiftool.exe" if _os() == "Windows" else "exiftool"
    found = shutil.which(exe)
    if found:
        return True, found
    if _os() == "Windows":
        bundled = project_root / "bin" / "windows" / "exiftool.exe"
        if bundled.exists():
            return True, str(bundled)
    return False, ""


def fetch_exiftool_windows(project_root: Path, dry_run: bool) -> bool:
    dest_dir = project_root / "bin" / "windows"
    dest_exe = dest_dir / "exiftool.exe"
    if dry_run:
        print(f"  [dry-run] fetch ExifTool -> {dest_exe}")
        return True
    try:
        print("  Resolving latest ExifTool version...")
        with urllib.request.urlopen(EXIFTOOL_VERSION_URL, timeout=15) as resp:
            ver = resp.read().decode("ascii").strip()
        if not ver:
            raise RuntimeError("empty version response")
        url = EXIFTOOL_WIN_URL_TEMPLATE.format(ver=ver)
        print(f"  Downloading {url}")
        dest_dir.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory() as tmp:
            zip_path = Path(tmp) / "exiftool.zip"
            with urllib.request.urlopen(url, timeout=120) as resp, open(zip_path, "wb") as out:
                shutil.copyfileobj(resp, out)
            with zipfile.ZipFile(zip_path) as zf:
                exe_member = None
                for name in zf.namelist():
                    base = Path(name).name.lower()
                    if base.startswith("exiftool") and base.endswith(".exe"):
                        exe_member = name
                        break
                if exe_member is None:
                    raise RuntimeError("exiftool(-k).exe not found in archive")
                zf.extractall(tmp)
                extracted = Path(tmp) / exe_member
                support_dir = None
                for name in zf.namelist():
                    norm = name.replace("\\", "/").lower()
                    if norm.startswith("exiftool-") and "/exiftool_files/" in norm:
                        top = name.split("/")[0]
                        support_dir = Path(tmp) / top / "exiftool_files"
                        break
                shutil.copy2(extracted, dest_exe)
                if support_dir and support_dir.is_dir():
                    target_support = dest_dir / "exiftool_files"
                    if target_support.exists():
                        shutil.rmtree(target_support)
                    shutil.copytree(support_dir, target_support)
        print(f"  ExifTool installed at {dest_exe}")
        return True
    except Exception as e:
        print(f"  WARNING: ExifTool auto-download failed: {e}", file=sys.stderr)
        print("  You can download manually from https://exiftool.org and place exiftool.exe in bin/windows/.")
        return False


def do_install(project_root: Path, dry_run: bool, skip_exiftool: bool) -> int:
    scripts_dir = resolve_scripts_comp_dir()
    plugin_home = Path(os.path.expanduser("~")) / ".media_relinker" / "plugin"
    print(f"Launcher:        {scripts_dir}")
    print(f"Plugin payload:  {plugin_home}")

    src_pkg = project_root / PACKAGE_NAME
    src_vendor = project_root / VENDOR_NAME
    src_entry = project_root / ENTRY_SCRIPT_REL

    if not src_pkg.is_dir():
        print(f"ERROR: package not found at {src_pkg}", file=sys.stderr)
        return 2
    if not src_vendor.is_dir():
        print(f"ERROR: vendor folder not found at {src_vendor}", file=sys.stderr)
        return 2
    if not src_entry.is_file():
        print(f"ERROR: entry script not found at {src_entry}", file=sys.stderr)
        return 2

    if not dry_run:
        scripts_dir.mkdir(parents=True, exist_ok=True)
        plugin_home.mkdir(parents=True, exist_ok=True)

    dst_pkg = plugin_home / PACKAGE_NAME
    dst_vendor = plugin_home / VENDOR_NAME
    dst_entry = scripts_dir / ENTRY_SCRIPT_BASENAME

    existing = dst_pkg.exists() or dst_entry.exists()
    if existing and not dry_run:
        if not prompt_yes_no("An existing install was found. Overwrite?"):
            print("Aborted.")
            return 1

    if not skip_exiftool and _os() == "Windows":
        ok, _ = find_exiftool(project_root)
        if not ok:
            print("ExifTool not found. Attempting auto-download...")
            fetch_exiftool_windows(project_root, dry_run)


    copy_tree(src_pkg, dst_pkg, dry_run)
    copy_tree(src_vendor, dst_vendor, dry_run)
    copy_file(src_entry, dst_entry, dry_run)

    src_bin = project_root / "bin"
    if src_bin.is_dir():
        dst_bin = plugin_home / "bin"
        print(f"Copying bundled binaries -> {dst_bin}")
        copy_tree(src_bin, dst_bin, dry_run)

    ok, path = find_exiftool(project_root)
    if ok:
        print(f"ExifTool: found at {path}")
    else:
        print("ExifTool: NOT FOUND.")
        if _os() == "Darwin":
            print("  Install with: brew install exiftool")
        elif _os() == "Linux":
            print("  Install with: sudo apt install libimage-exiftool-perl")

    if dry_run:
        print("Dry run complete. No files were modified.")
    else:
        print("Install complete.")
        print("Next steps:")
        print("  1. Restart DaVinci Resolve.")
        print("  2. Open a project with offline media.")
        print("  3. Workspace -> Scripts -> Media Relinker")
    return 0


def do_uninstall(dry_run: bool) -> int:
    scripts_dir = resolve_scripts_comp_dir()
    plugin_home = Path(os.path.expanduser("~")) / ".media_relinker" / "plugin"
    dst_entry = scripts_dir / ENTRY_SCRIPT_BASENAME
    legacy_py_entry = scripts_dir / "Media Relinker.py"

    print(f"Launcher:        {scripts_dir}")
    print(f"Plugin payload:  {plugin_home}")

    if not any(p.exists() for p in (dst_entry, plugin_home, legacy_py_entry)):
        print("Nothing to uninstall.")
        return 0

    if not dry_run and not prompt_yes_no("Remove installed Media Relinker files?"):
        print("Aborted.")
        return 1

    remove_path(dst_entry, dry_run)
    remove_path(legacy_py_entry, dry_run)
    remove_path(plugin_home, dry_run)
    print("Uninstall complete." if not dry_run else "Dry run complete.")
    return 0


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description="Install Media Relinker (Lua) into DaVinci Resolve.")
    parser.add_argument("--uninstall", action="store_true")
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--skip-exiftool", action="store_true")
    parser.add_argument("-y", "--yes", action="store_true")
    args = parser.parse_args(argv)

    global _ASSUME_YES
    _ASSUME_YES = args.yes

    project_root = Path(__file__).resolve().parent
    try:
        if args.uninstall:
            return do_uninstall(args.dry_run)
        return do_install(project_root, args.dry_run, args.skip_exiftool)
    except RuntimeError as e:
        print(f"ERROR: {e}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
