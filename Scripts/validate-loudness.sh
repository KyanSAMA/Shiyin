#!/bin/bash
# Compare lmtool's BS.1770 loudness with ffmpeg's ebur128 on a real-library sample: every 192 kHz file, five 96 kHz,
# five MP3 and four others; integrated within 0.5 LU, lossless sample peaks within 0.1 dB, ≥20× realtime. Read-only. Usage: Scripts/validate-loudness.sh [root=~/Music]
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT=${1:-$HOME/Music}
swift build -q -c release --product lmtool
LMTOOL=$(swift build -c release --show-bin-path)/lmtool

python3 - "$LMTOOL" "$ROOT" <<'PY'
import json, re, subprocess, sys
lmtool, root = sys.argv[1], sys.argv[2]
tags = json.loads(subprocess.run([lmtool, "tags", root], capture_output=True).stdout)
ok = [e for e in tags if "error" not in e]
pick = ([e for e in ok if e["sampleRate"] == 192000]
        + [e for e in ok if e["sampleRate"] == 96000][:5]
        + [e for e in ok if e["format"] == "mp3"][:5]
        + [e for e in ok if e["format"] == "flac" and e["sampleRate"] in (44100, 48000)][:4])
ours = {e["path"]: e for e in json.loads(subprocess.run([lmtool, "loudness"] + [e["path"] for e in pick], capture_output=True).stdout)}

def ffmpeg(path):
    err = subprocess.run(["ffmpeg", "-hide_banner", "-nostats", "-i", path, "-vn", "-af",
                          "ebur128=peak=sample:framelog=quiet:dualmono=true", "-f", "null", "-"], capture_output=True, text=True).stderr
    summary = err[err.rfind("Summary:"):] if "Summary:" in err else ""
    integrated = re.search(r"I:\s+(-?[\d.]+) LUFS", summary)
    peak = re.search(r"Sample peak:\s+Peak:\s+(-?[\d.inf]+) dBFS", summary)
    return (float(integrated.group(1)), float(peak.group(1))) if integrated and peak else None

worst, failures, slowest = 0.0, [], float("inf")
for e in pick:
    name = e["path"].rsplit("/", 1)[1]
    mine, theirs = ours.get(e["path"], {}), ffmpeg(e["path"])
    if mine.get("integrated") is None or theirs is None:
        print(f"{e['sampleRate']:>6} {e['format']:4} unmeasured: ours {mine.get('error', mine.get('integrated'))} ffmpeg {theirs}  {name}")
        failures.append(name)
        continue
    di, dp = abs(mine["integrated"] - theirs[0]), abs(mine["samplePeakDb"] - theirs[1])
    worst, slowest = max(worst, di), min(slowest, mine["speed"])
    print(f"{e['sampleRate']:>6} {e['format']:4} ours {mine['integrated']:7.2f} ffmpeg {theirs[0]:7.2f} Δ{di:5.2f}  peak Δ{dp:4.2f}  {mine['speed']:5.0f}x  {name}")
    # Lossy peaks depend on the decoder (ffmpeg's float MP3 decoder overshoots 0 dBFS differently from Apple's, which
    # is what playback uses), so peaks are only compared for lossless files.
    if di > 0.5 or (e.get("codec") in ("flac", "alac", "pcm") and dp > 0.1): failures.append(name)
print(f"files={len(pick)} worst Δ={worst:.2f} LU slowest={slowest:.0f}x realtime failures={failures}")
sys.exit(1 if failures or slowest < 20 else 0)
PY
