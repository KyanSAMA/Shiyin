#!/bin/bash
# Tag writing on COPIES of real files (the library is only read): picks FLACs with and without padding and MP3s with
# ID3v2.3, v2.4 and a "163 key", writes tags and a cover with lmtool, checks them with flac -t / metaflac / ffprobe /
# ffmpeg, restores, and requires the result to equal the copy byte for byte. Usage: Scripts/validate-write.sh [root=~/Music]
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT=${1:-$HOME/Music}
OUT=.build/write-check
rm -rf "$OUT" && mkdir -p "$OUT"
swift build -q --product lmtool
LMTOOL=$(swift build --show-bin-path)/lmtool
Scripts/make-fixtures.sh

python3 - "$ROOT" "$OUT" "$LMTOOL" <<'PY'
import glob, hashlib, json, os, shutil, subprocess, sys

root, out, lmtool = sys.argv[1:4]
files = sorted(glob.glob(f"{root}/**/*.flac", recursive=True)) + sorted(glob.glob(f"{root}/**/*.mp3", recursive=True))
files = [f for f in files if "/Music/Music/" not in f]

def run(*args, check=True):
    result = subprocess.run(args, capture_output=True)
    if check and result.returncode != 0:
        raise SystemExit(f"{' '.join(args[:3])}… failed: {result.stderr.decode(errors='replace')[:400]}")
    return result.stdout.decode("utf-8", "replace")

def padded(path):
    return "type: 1 (PADDING)" in run("metaflac", "--list", "--block-type=PADDING", path, check=False)

def id3(path):
    with open(path, "rb") as f:
        head = f.read(1 << 16)
    return (head[3] if head.startswith(b"ID3") else None), b"163 key" in head

picks = {}
for f in files:
    if f.endswith(".flac"):
        picks.setdefault("flac, padding" if padded(f) else "flac, no padding", f)
    else:
        version, ncm = id3(f)
        if version in (3, 4): picks.setdefault(f"mp3, ID3v2.{version}", f)
        if ncm: picks.setdefault("mp3, 163 key", f)
    if len(picks) == 5: break

lyrics = os.path.join(out, "lyrics.lrc")
with open(lyrics, "w") as f:
    f.write("[00:00.00]作词 : 甲\n[00:01.00]写入测试\n[00:02.00]第二行\n")
cover = ".build/fixtures/cover-a.png"
failures = 0
for kind, source in picks.items():
    name = f"{len(os.listdir(out))}-{os.path.basename(source)}"
    target, pristine, backup = os.path.join(out, name), os.path.join(out, "orig-" + name), os.path.join(out, name + ".json")
    shutil.copyfile(source, target)
    shutil.copyfile(source, pristine)
    run(lmtool, "write-tags", target, "--backup", backup, "--set", "title=写入测试 Title", "--set", "artists=甲/乙",
        "--set", "album=测试专辑", "--set", "year=2001", "--set", "trackNo=7", "--set", "genre=Test", "--cover", cover, "--lyrics", lyrics)
    problems = []
    if target.endswith(".flac"):
        run("flac", "-t", "-s", target)
        tags = run("metaflac", "--export-tags-to=-", target)
        for expected in ["TITLE=写入测试 Title", "ARTIST=甲", "ARTIST=乙", "ALBUM=测试专辑", "DATE=2001", "GENRE=Test", "LYRICS=[00:00.00]作词 : 甲"]:
            if expected not in tags: problems.append(f"missing {expected}")
        picture = subprocess.run(["metaflac", "--export-picture-to=-", target], capture_output=True).stdout
        if picture != open(cover, "rb").read(): problems.append("cover differs")
    else:
        probe = json.loads(run("ffprobe", "-v", "error", "-show_entries", "format_tags", "-of", "json", target))["format"]["tags"]
        for key, value in [("title", "写入测试 Title"), ("album", "测试专辑"), ("genre", "Test")]:
            if probe.get(key) != value: problems.append(f"{key}: {probe.get(key)!r}")
        if kind == "mp3, 163 key" and "163 key" not in open(target, "rb").read(1 << 16).decode("latin1"): problems.append("163 key lost")
    decode = subprocess.run(["ffmpeg", "-v", "error", "-i", target, "-f", "null", "-"], capture_output=True).stderr
    if decode.strip(): problems.append("decode: " + decode.decode(errors="replace")[:200])
    run(lmtool, "restore-tags", target, "--backup", backup)
    if open(target, "rb").read() != open(pristine, "rb").read(): problems.append("restore is not byte-identical")
    failures += bool(problems)
    print(f"{'FAIL' if problems else 'ok  '} {kind}: {os.path.basename(source)}" + "".join(f"\n       {p}" for p in problems))
missing = {"flac, padding", "flac, no padding", "mp3, ID3v2.3", "mp3, ID3v2.4", "mp3, 163 key"} - picks.keys()
if missing: print("not found in the library:", ", ".join(sorted(missing)))
sys.exit(1 if failures else 0)
PY
