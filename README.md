<div align="center">

# Media Relinker for DaVinci Resolve

**Automatically find and relink offline media clips using deep metadata matching.**

Works on free DaVinci Resolve and Studio. Everything runs locally.

[![Resolve](https://img.shields.io/badge/DaVinci%20Resolve-18%2B-ff3e00?logo=davinciresolve)](https://www.blackmagicdesign.com/products/davinciresolve)
[![Platform](https://img.shields.io/badge/platform-Windows%20%7C%20macOS%20%7C%20Linux-blue)]()
[![Lua](https://img.shields.io/badge/Lua-5.1-000080?logo=lua)]()
[![License: MIT](https://img.shields.io/badge/license-MIT-green)](LICENCE)
[![PRs Welcome](https://img.shields.io/badge/PRs-welcome-brightgreen)](#contributing)

</div>

![Before vs after: offline clips in Resolve, then relinked via Media Relinker](docs/before-vs-after.png)

---

## Overview

When a project opens with missing footage (drive letter changed, files moved, camera cards re-ingested to a new NAS), Media Relinker scans folders you point it at, extracts metadata with ExifTool, and scores every file on disk against every offline clip in your Media Pool.

Ranked candidates appear in a tree grouped into High, Medium, Low and None buckets. High-confidence rows are pre-ticked for auto-relink. Medium rows are shown as strong suggestions. Low and None rows stay unchecked. One click relinks confirmed matches through Resolve's scripting API.

---

## Table of contents

1. [Why this plugin](#why-this-plugin)
2. [Features](#features)
3. [Requirements](#requirements)
4. [Installation](#installation)
5. [Usage](#usage)
6. [How matching works](#how-matching-works)
7. [Configuration](#configuration)
8. [Troubleshooting](#troubleshooting)
9. [FAQ](#faq)
10. [Limitations](#limitations)
11. [Contributing](#contributing)
12. [License](#license)

---

## Why this plugin

| Benefit | What it means |
|---|---|
| **Works on free DaVinci Resolve** | Runs inside Resolve's built-in Fusion Lua interpreter. No external scripting server. No Studio requirement. |
| **Not fooled by a rename** | Matches on 17 weighted metadata fields: timecode, duration, resolution, codec, camera serial, reel name, filename fuzzy, audio channels, and more. |
| **Fast** | Persistent ExifTool daemon, on-disk metadata cache keyed by size and mtime, duration-delta fast-reject, batched Resolve property reads. |
| **Reversible** | Every relink is journalled. A History window lets you revert or swap in one of the alternatives captured at match time without a re-scan. |
| **Configurable** | Thresholds and per-field scoring weights live in a settings dialog and persist across restarts. |

---

## Features

- Scan local folders and mapped network drives, with optional recursion.
- 17-field weighted scoring (timecode, duration, FPS, resolution, codec, camera model and serial, reel name, UMID, MediaUID, filename fuzzy match, audio channels, file size, modification time).
- Ambiguity detection. Flags any clip where two or more files score above the auto-match threshold, and any source file that multiple offline clips would all claim.
- Relink history with **Revert** and **Re-pick alternative** actions.
- Persistent **Show:** filter dropdown (High / Medium / Low / No match).
- Settings dialog for thresholds and per-field weights.
- Resumable metadata caching. The second scan over the same footage is near-instant.
- Session logs at `~/.media_relinker/logs/session_*.log`.

---

## Requirements

| Component | Minimum version | Notes |
|---|---|---|
| DaVinci Resolve | 18.0 | Free or Studio. |
| Operating system | Windows 10, macOS 10.15, Ubuntu 20.04 | |
| ExifTool | 12.0 | Auto-downloaded on Windows. macOS: `brew install exiftool`. Linux: `sudo apt install libimage-exiftool-perl`. |
| Python | 3.7 | Only for running `install.py`. The plugin itself runs entirely in Resolve's Lua. |
| Lua (optional) | 5.1 | Only if you prefer `install.lua` over the Python installer. |

---

## Installation

Clone or download the repository, then from the project folder:

### Option 1: Python installer (recommended)

Auto-downloads ExifTool on Windows.

```bash
python install.py
```

### Option 2: Pure-Lua installer

No ExifTool auto-download.

```bash
lua install.lua
```

### What the installer does

```
media_relinker/      ->  ~/.media_relinker/plugin/media_relinker/
vendor/              ->  ~/.media_relinker/plugin/vendor/
Scripts/Comp/*.lua   ->  <Resolve Fusion scripts dir>/Scripts/Comp/
```

Set `MEDIA_RELINKER_HOME=<repo root>` to override the install root for portable or multi-user setups.

### Uninstall

```bash
python install.py --uninstall
```

---

## Usage

![Media Relinker GUI — scan results with per-field match quality indicators](docs/GUI.png)

1. Launch DaVinci Resolve and open a project with offline media.
2. Open **Workspace > Scripts > Comp > Media Relinker**.
3. Click **Browse folder...** and add one or more folders to scan. Tick **Include subdirectories** if your footage is nested.
4. Press **Scan**. ExifTool extracts metadata (cached after the first run), then every file is scored against every offline clip.
5. Review the tree. Rows at or above the auto-match threshold (default 70) are pre-ticked. Expand any row to see alternative candidates.
6. Adjust the ticks if needed, then press **Relink Selected**.

### Handy buttons

| Button | Purpose |
|---|---|
| **Show:** | Filter rows by match quality (High, Medium, Low, No match). Choice persists across sessions. |
| **History** | List every past relink. Revert to the previous offline path, or re-pick an alternative captured at match time. |
| **Settings** | Tune auto / strong / weak thresholds and per-field scoring weights. |
| **Clear cache** | Drop the ExifTool metadata cache. Next scan re-reads every file. |

---

## How matching works

Every offline clip and every on-disk file is reduced to a **signature**, a table of metadata fields. The matcher scores each file against each clip with a weighted sum where every field contributes independently:

```
score = sum over fields of (weight_i * match_i)
```

`match_i` is `1` for an exact match, fractional for a fuzzy match (filename Levenshtein, timecode within N frames, duration within 1 %), and `0` otherwise. Weights are configurable. Defaults prioritise strong indicators (UMID, timecode and duration combined, camera serial plus date) over weak ones (filename, FPS alone).

Before scoring, a **fast-reject gate** drops any candidate whose duration differs from the target clip by more than one second. This skips the heavy per-candidate parsing for files that can't possibly be a match, and accounts for most of the scan-time speed-up on large libraries.

### Score buckets

| Bucket | Default range | Default action |
|---|---|---|
| **High** | 70 and up | Pre-ticked for relink |
| **Medium** | 50 to 69 | Shown, not ticked |
| **Low** | 20 to 49 | Hidden by default filter |
| **None** | below 20 | Hidden by default filter |

You always retain veto power before any clip is relinked.

---

## Configuration

Settings live at `~/.media_relinker/config.json`. Edit directly, or use the **Settings** dialog inside the plugin.

```json
{
  "auto_match_threshold": 70,
  "strong_threshold": 50,
  "weak_threshold": 20,
  "weights": {
    "umid_exact": 100,
    "tc_duration_exact": 80,
    "start_tc_exact": 40,
    "duration_frame_exact": 30,
    "camera_serial_date": 40,
    "reel_name_exact": 25,
    "filename_exact": 10,
    "filename_fuzzy": 5
  },
  "extensions": {
    "video": [".mov", ".mp4", ".mxf", ".avi", ".mkv", ".braw", ".r3d", ".m4v"],
    "image": [".jpg", ".jpeg", ".png", ".tiff", ".tif", ".dpx", ".exr"],
    "audio": [".wav", ".aif", ".aiff", ".mp3", ".flac", ".aac"]
  },
  "show_filters": {"high": true, "medium": true, "low": true, "none": true}
}
```

### Data directory layout

```
~/.media_relinker/
  config.json          user preferences, weights, thresholds
  cache.json           ExifTool metadata cache (size + mtime keyed)
  relink_log.json      reversible journal (capped at 2000 entries)
  history.json         per-scan session summaries
  logs/
    session_*.log      per-session log files
  plugin/
    media_relinker/    installed Lua package
    vendor/            vendored dependencies (json.lua)
    bin/               bundled ExifTool (Windows only)
```

---

## Troubleshooting

<details>
<summary><b>The script entry doesn't appear under Workspace > Scripts.</b></summary>

Re-run `python install.py` and restart Resolve. Verify the file landed under Resolve's `Fusion/Scripts/Comp/` directory.

</details>

<details>
<summary><b>"Could not locate the media_relinker Lua package"</b></summary>

The installer didn't complete, or `MEDIA_RELINKER_HOME` points somewhere wrong. Re-run the installer, or set the env var to the repo root.

</details>

<details>
<summary><b>ExifTool not found</b></summary>

- **Windows**: drop `exiftool.exe` into `~/.media_relinker/plugin/bin/windows/`.
- **macOS**: `brew install exiftool`.
- **Linux**: `sudo apt install libimage-exiftool-perl`.

</details>

<details>
<summary><b>"No offline clips found" but the Media Pool shows red badges</b></summary>

Only Video, Audio, Still and Image clip types are scanned. Timelines, Compound Clips and Fusion Comps are skipped by design. Otherwise, check `~/.media_relinker/logs/session_*.log` for the offline-probe section.

</details>

<details>
<summary><b>A Windows cmd window flashes briefly during scan</b></summary>

A single cmd flash per scan is expected. Lua 5.1's `io.popen` routes through `cmd.exe` on Windows, and the persistent ExifTool daemon consolidates the whole scan into a single process launch. No cmd window should appear during clip matching itself.

</details>

---

## FAQ

<details>
<summary><b>Does it work on free DaVinci Resolve?</b></summary>

Yes. That's the main reason this plugin exists. It runs inside Resolve's built-in Fusion Lua interpreter, so it does not need the Studio-only external scripting server.

</details>

<details>
<summary><b>Does it modify my original media files?</b></summary>

No. Media Relinker only writes to Resolve's Media Pool (via `ReplaceClip`). Your source files on disk are never touched. Every relink is journalled and reversible.

</details>

<details>
<summary><b>What about RAW and camera-proprietary formats?</b></summary>

BRAW, R3D, ARRIRAW, ProRes, DNxHR, H.264, HEVC and common still formats all work. Anything ExifTool can read metadata from is supported. Timecode and duration are the strongest signals, so formats that carry accurate timecode relink most reliably.

</details>

<details>
<summary><b>Can I relink proxies or transcodes back to camera originals (or vice versa)?</b></summary>

Yes, as long as timecode and duration line up. Use the Settings dialog to lower `auto_match_threshold` if your proxies carry fewer matching metadata fields than the originals.

</details>

<details>
<summary><b>Does this replace Resolve's built-in "Relink Clips"?</b></summary>

They complement each other. Resolve's built-in tool matches by filename and folder structure, which is fast when files have simply moved. Media Relinker shines when filenames changed, folder structures were reorganised, or the original and replacement share only deep metadata.

</details>

---

## Limitations

- ExifTool is required. There is no built-in fallback extractor.
- Scanning is single-threaded (Fusion Lua has no threadpool). Batching keeps wall-clock time acceptable in practice.

---

## Contributing

Pull requests welcome. The codebase is small (around 3 000 lines across a dozen modules) and heavily commented.

<details>
<summary><b>Module map</b></summary>

| Module | Responsibility |
|---|---|
| `main.lua` | Entry point, scan orchestration, relink, revert, re-pick. |
| `matcher.lua` | Scoring pipeline, ambiguity and shared-source detection. |
| `exiftool.lua` | Persistent daemon, argfile batching, output normalisation. |
| `resolve_interface.lua` | Media Pool walking, offline clip enumeration, signature extraction via batched `GetClipProperty()`. |
| `ui.lua` | Fusion UIManager GUI (tree, filter dropdown, history, settings). |
| `scanner.lua` | Recursive media-file walk, extension filtering. |
| `cache.lua` | JSON-backed metadata cache. |
| `config.lua` | User settings, path helpers. |
| `logger.lua` | Session-file and stderr logging. |
| `fs.lua` | Filesystem abstraction (LuaFileSystem, `bmd.readdir`, `io.open`). |
| `history.lua`, `relink_log.lua` | Scan summaries and reversible relink journal. |
| `levenshtein.lua`, `timecode.lua`, `json.lua` | Small utility modules. |

</details>

Run tests with `lua tests/run.lua` from the repo root.

---

## License

MIT. See [LICENCE](LICENCE). Vendored `vendor/json.lua` is by [rxi](https://github.com/rxi/json.lua), MIT-licensed.

---

<div align="center">

**Keywords**

DaVinci Resolve plugin, relink offline media, missing clips, Media Pool, free DaVinci Resolve, Fusion Lua, ExifTool, timecode matching, BRAW, R3D, ProRes, DNxHR.

</div>
