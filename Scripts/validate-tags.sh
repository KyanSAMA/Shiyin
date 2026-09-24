#!/bin/bash
# Cross-check lmtool's tag/cover parsing against metaflac (FLAC) and ffprobe/ffmpeg (MP3/WAV) on a real library.
# Read-only. Usage: Scripts/validate-tags.sh [root=~/Music]
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT=${1:-$HOME/Music}
swift build -q --product lmtool
LMTOOL=$(swift build --show-bin-path)/lmtool
JSON=$(mktemp)
trap 'rm -f "$JSON"' EXIT
"$LMTOOL" tags --sha "$ROOT" > "$JSON"

python3 - "$JSON" <<'PY'
import hashlib, json, subprocess, sys

def run(*args):
    return subprocess.run(args, capture_output=True).stdout

def flac_tags(path):
    """metaflac prints NAME=value per comment; values may span lines, so re-join continuation lines."""
    out, current = {}, None
    for line in run("metaflac", "--export-tags-to=-", path).decode("utf-8", "replace").split("\n"):
        key, sep, val = line.partition("=")
        if sep and key and key.replace("_", "").replace(" ", "").isalnum() and key.isascii():
            current = [key.upper(), val]
            out.setdefault(current[0], []).append(val)
        elif current:
            out[current[0]][-1] += "\n" + line
    return {k: [v.strip() for v in vs if v.strip()] for k, vs in out.items() if any(v.strip() for v in vs)}

entries = json.load(open(sys.argv[1]))
mismatches, covers, checked = [], 0, 0
for e in entries:
    path = e["path"]
    if "error" in e:
        mismatches.append((path, "parse error", e["error"])); continue
    checked += 1
    mine = e["tags"]
    if e["format"] == "flac":
        info = run("metaflac", "--show-sample-rate", "--show-bps", "--show-channels", "--show-total-samples", path).split()
        want = [int(x) for x in info]
        got = [e["sampleRate"], e["bitDepth"], e["channels"], e["frameCount"]]
        if want != got: mismatches.append((path, "streaminfo", (want, got)))
        theirs = flac_tags(path)
        for key in set(theirs) | set(mine):
            if theirs.get(key, []) != mine.get(key, []):
                mismatches.append((path, key, (theirs.get(key), mine.get(key))))
        pic = run("metaflac", "--export-picture-to=-", path)
        if pic or e.get("coverSHA256"):
            covers += 1
            if hashlib.sha256(pic).hexdigest() != e.get("coverSHA256"):
                mismatches.append((path, "cover sha", None))
    else:
        probe = json.loads(run("ffprobe", "-v", "error", "-show_format", "-show_streams", "-of", "json", path))
        audio = next(s for s in probe["streams"] if s["codec_type"] == "audio")
        if int(audio["sample_rate"]) != e["sampleRate"] or int(audio["channels"]) != e["channels"]:
            mismatches.append((path, "stream", (audio["sample_rate"], audio["channels"], e["sampleRate"], e["channels"])))
        if abs(float(probe["format"]["duration"]) - e["duration"]) > 0.1:
            mismatches.append((path, "duration", (probe["format"]["duration"], e["duration"])))
        ftags = {k.lower(): v for k, v in probe["format"].get("tags", {}).items()}
        for key, fkey in [("TITLE", "title"), ("ARTIST", "artist"), ("ALBUM", "album"), ("ALBUMARTIST", "album_artist"),
                          ("COMPOSER", "composer"), ("TRACKNUMBER", "track"), ("DISCNUMBER", "disc"), ("GENRE", "genre")]:
            theirs = ftags.get(fkey, "").strip()
            ours = ";".join(mine.get(key, []))
            if theirs != ours: mismatches.append((path, key, (theirs, ours)))
        if e.get("coverSHA256") or any(s.get("disposition", {}).get("attached_pic") for s in probe["streams"]):
            covers += 1
            pic = run("ffmpeg", "-v", "error", "-i", path, "-an", "-map", "0:v:0", "-c", "copy", "-f", "image2pipe", "-")
            if hashlib.sha256(pic).hexdigest() != e.get("coverSHA256"):
                mismatches.append((path, "cover sha", None))

for m in mismatches[:40]: print("MISMATCH", *m)
print(f"checked={checked} covers={covers} mismatches={len(mismatches)}")
sys.exit(1 if mismatches else 0)
PY
