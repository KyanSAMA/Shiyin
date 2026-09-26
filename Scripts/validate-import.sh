#!/bin/bash
# NetEase import on COPIES of the real .ncm files (the folder is only read): decrypts each with `lmtool ncm --fill`
# (live NetEase requests), then checks the tagged FLAC / MP3 with ffprobe / flac / ffmpeg and that ~/Music wasn't written.
# Usage: Scripts/validate-import.sh [folder=~/Music/网易云音乐]
set -euo pipefail
cd "$(dirname "$0")/.."
SRC=${1:-$HOME/Music/网易云音乐}
OUT=.build/import-check
rm -rf "$OUT" && mkdir -p "$OUT/src" "$OUT/lib"
swift build -q --product lmtool
LMTOOL=$(swift build --show-bin-path)/lmtool
STAMP=$(mktemp)
find "$SRC" -maxdepth 1 \( -name '*.ncm' -o -name '*.lrc' \) -exec cp {} "$OUT/src/" \;

status=0
python3 - "$OUT" "$LMTOOL" <<'PY' || status=$?
import glob, json, os, subprocess, sys
out, lmtool = sys.argv[1:3]
failures = 0
for ncm in sorted(glob.glob(f"{out}/src/*.ncm")):
    problems = []
    result = subprocess.run([lmtool, "ncm", ncm, "--out", f"{out}/lib", "--fill"], capture_output=True)
    if result.returncode:
        print("FAIL", os.path.basename(ncm), result.stderr.decode(errors="replace")[:300]); failures += 1; continue
    info = json.loads(result.stdout)
    placed = info["placed"]
    tags = json.loads(subprocess.run(["ffprobe", "-v", "error", "-show_entries", "format_tags", "-of", "json", placed],
                                     capture_output=True).stdout)["format"].get("tags", {})
    tags = {k.lower(): v for k, v in tags.items()}
    for key in ["title", "artist", "album"]:
        if not tags.get(key): problems.append(f"no {key}")
    if not any("163 key" in v for v in tags.values()): problems.append("163 key missing")
    if not tags.get("lyrics") and not any(k.startswith("lyrics") for k in tags): problems.append("no lyrics")
    if placed.endswith(".flac") and subprocess.run(["flac", "-t", "-s", placed]).returncode: problems.append("flac -t failed")
    decode = subprocess.run(["ffmpeg", "-v", "error", "-i", placed, "-f", "null", "-"], capture_output=True).stderr
    if decode.strip(): problems.append("decode: " + decode.decode(errors="replace")[:200])
    failures += bool(problems)
    print(f"{'FAIL' if problems else 'ok  '} {os.path.basename(placed)}  [{info['format']}, musicId {info['musicId']}, "
          f"{tags.get('title')} / {tags.get('artist')} / {tags.get('album')}, track {tags.get('track')}, date {tags.get('date')}]"
          + "".join(f"\n       {p}" for p in problems))
sys.exit(1 if failures else 0)
PY
changed=$(find "$HOME/Music" -path "$HOME/Music/Music" -prune -o -cnewer "$STAMP" -not -name .DS_Store -print) || { echo "!! find failed"; status=1; }
rm -f "$STAMP"
if [ -n "$changed" ]; then echo "!! ~/Music changed:"; echo "$changed" | head -5; exit 1; fi
exit $status
