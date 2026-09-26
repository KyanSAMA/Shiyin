#!/bin/bash
# Generate the deterministic self-test library in .build/fixtures (skipped when already current).
# Requires ffmpeg and metaflac. Layout:
#   library/   11 playable files across FLAC 44.1/96/192 kHz, ID3v2.3/2.4 MP3, ALAC M4A, WAV, untagged, sidecar LRC,
#              and a gapless pair (one 375 Hz tone split mid-buffer, 12 s = whole periods)
#   library/Music/  a file the self-tests exclude;  library/junk/  non-audio files the scanner must ignore
#   extra/     files copied in at runtime to exercise FSEvents
#   netease/   audio the self-tests wrap into .ncm files (tags junk, as inside real ones), and a plain FLAC to import
#   loudness/  levels exact to ffmpeg's ebur128: Level Album (Loud −8 LUFS sine, Quiet −30 LUFS pink noise), Mid −20 LUFS,
#              Mono −20 LUFS (dual mono), Peaky.wav (−30 LUFS noise with single-sample spikes to full scale),
#              Step (the Gapless tone with part 2 6 dB down: track gains must switch exactly on the join)
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION=8
OUT=.build/fixtures
[ "$(cat "$OUT/.version" 2>/dev/null)" = "$VERSION" ] && exit 0
rm -rf "$OUT"
mkdir -p "$OUT"
LIB=$OUT/library

ff() { ffmpeg -v error -y "$@"; }

ff -f lavfi -i "color=c=0x2f5aa8:s=600x600,drawbox=x=100:y=100:w=400:h=400:color=0xf2c14e:t=fill" -frames:v 1 "$OUT/cover-a.png"
ff -f lavfi -i "color=c=0x8a2be2:s=600x600,drawbox=x=0:y=300:w=600:h=300:color=0x20b2aa:t=fill" -frames:v 1 "$OUT/cover-b.png"

# audio <out> <seconds> <rate> <codec args> <cover.png|-> [ffmpeg metadata args...]; FREQ (default 440 Hz) keeps files of
# the same length and rate from being the same recording (enrichment is keyed by audio content)
audio() {
  local out=$1 seconds=$2 rate=$3 codec=$4 cover=$5
  shift 5
  mkdir -p "$(dirname "$out")"
  local source=(-f lavfi -i "sine=frequency=${FREQ:-440}:duration=$seconds:sample_rate=$rate")
  if [ "$cover" = - ]; then
    ff "${source[@]}" $codec "$@" "$out"
  else
    ff "${source[@]}" -i "$cover" -map 0:a -map 1:v $codec -c:v copy -disposition:v attached_pic \
       -metadata:s:v comment="Cover (front)" "$@" "$out"
  fi
}
FLAC16="-c:a flac -sample_fmt s16"
FLAC24="-c:a flac -sample_fmt s32 -bits_per_raw_sample 24"

LYRICS=$'[00:00.00] 作词 : Ayase\n[00:00.30] 作曲 : Ayase'
i=1
for pair in "沈むように溶けてゆくように|像是要沉溺 像是要融化一般" "二人だけの空が広がる夜に|在只有两人的天空展开的夜晚" \
            "「さよなら」だけだった|只有一句「再见」" "その一言で全てが分かった|仅凭这一句便明白了一切" \
            "日が沈み出した空と君の姿|开始日落的天空与你的身影" "フェンス越しに重なっていた|隔着围栏重叠在一起" \
            "初めて会った日から|从初次相遇的那天起" "僕の心の全てを奪った|你就夺走了我的全部心意" \
            "どこか儚い空気を纏う君は|身上笼罩着虚幻气息的你" "寂しい目をしてたんだ|总带着寂寞的眼神" \
            "いつだってチックタックと|无论何时都滴答作响" "鳴る世界で何度だってさ|在这鸣响的世界里无数次"; do
  LYRICS+=$'\n'"[00:$(printf %02d $i).00]${pair%%|*}"$'\n'"[00:$(printf %02d $i).00]${pair##*|}"
  i=$((i + 1))
done

audio "$LIB/THE BOOK/01 夜に駆ける.flac" 14 96000 "$FLAC24" "$OUT/cover-a.png" \
  -metadata title=夜に駆ける -metadata artist=YOASOBI -metadata album="THE BOOK" -metadata ALBUMARTIST=YOASOBI \
  -metadata track=1/2 -metadata date=2021-01-06 -metadata genre=J-Pop -metadata LYRICS="$LYRICS"
audio "$LIB/THE BOOK/02 群青.flac" 3 44100 "$FLAC16" "$OUT/cover-a.png" \
  -metadata title=群青 -metadata artist=YOASOBI -metadata album="THE BOOK" -metadata ALBUMARTIST=YOASOBI \
  -metadata track=2/2 -metadata date=2021 -metadata composer=Ayase
audio "$LIB/Hi-Res/192k.flac" 2 192000 "$FLAC24" "$OUT/cover-b.png" \
  -metadata title="Hi-Res 192k" -metadata album="Hi-Res Test" -metadata date=2024
metaflac --set-tag=ARTIST=小山百代 --set-tag=ARTIST=三森すずこ "$LIB/Hi-Res/192k.flac"
audio "$LIB/mp3/直到大地变成一颗酸橙.mp3" 3 48000 "-c:a libmp3lame -b:a 128k -id3v2_version 3" "$OUT/cover-b.png" \
  -metadata title=直到大地变成一颗酸橙 -metadata artist="塞壬唱片-MSR/平林佑人" -metadata album=直到大地变成一颗酸橙OST -metadata track=2
audio "$LIB/mp3/v24.mp3" 2 44100 "-c:a libmp3lame -b:a 128k -id3v2_version 4" - \
  -metadata title="ID3v2.4 测试" -metadata artist="miwa, 96猫"
audio "$LIB/m4a/春日影.m4a" 2 48000 "-c:a alac -sample_fmt s16p" - \
  -metadata title=春日影 -metadata artist=MyGO!!!!! -metadata album=迷跡波 -metadata composer=藤田淳平 -metadata track=3/10
audio "$LIB/wav/untagged.wav" 2 44100 "-c:a pcm_s16le" -
audio "$LIB/53.无标签标题.flac" 2 44100 "$FLAC16" -
FREQ=523 audio "$LIB/sidecar/歌.flac" 3 44100 "$FLAC16" -
printf '[00:00.50]侧边歌词第一行\n[00:01.50]第二行\n' > "$LIB/sidecar/歌.lrc"
printf '[00:00.20]一\n[00:00.60]二\n[00:01.00]三\n[00:01.40]四\n[00:01.80]五\n' > "$OUT/sidecar-5.lrc"

for part in 1 2; do
  trim=$([ $part = 1 ] && echo "end_sample=264601" || echo "start_sample=264601")
  mkdir -p "$LIB/Gapless"
  ff -f lavfi -i "sine=frequency=375:sample_rate=48000:duration=12" -af "atrim=$trim" $FLAC16 \
    -metadata title="Part $part" -metadata artist="Test Tone" -metadata ALBUMARTIST="Test Tone" -metadata album=Gapless \
    -metadata track=$part/2 "$LIB/Gapless/0$part Part $part.flac"
done

audio "$LIB/Music/excluded.flac" 1 44100 "$FLAC16" -
mkdir -p "$LIB/junk"
ff -i "$OUT/cover-a.png" "$LIB/junk/cover.jpg"
printf 'not audio' > "$LIB/junk/music_tag.db"

FREQ=660 audio "$OUT/extra/新歌.flac" 2 44100 "$FLAC16" - -metadata title=新歌 -metadata artist=YOASOBI
FREQ=700 audio "$OUT/netease/raw.flac" 2 44100 "$FLAC16" - -metadata title=junk -metadata comment=junk
FREQ=740 audio "$OUT/netease/raw.mp3" 2 44100 "-c:a libmp3lame -b:a 128k -id3v2_version 3" - -metadata title=junk
FREQ=780 audio "$OUT/netease/夜曲.flac" 2 44100 "$FLAC16" - -metadata title=夜曲 -metadata artist=周杰伦

# level <out> <LUFS> <mono|stereo> <lavfi source> [ffmpeg output args...]: measure once, then scale to the target
level() {
  local out=$1 target=$2 layout=$3 source=$4
  shift 4
  mkdir -p "$(dirname "$out")"
  local measured
  measured=$(ffmpeg -hide_banner -nostats -f lavfi -i "$source" -af "aformat=channel_layouts=$layout,ebur128=framelog=quiet:dualmono=true" \
    -f null - 2>&1 | awk '/^ +I:/ { v = $2 } END { print v }')
  ff -f lavfi -i "$source" -af "aformat=channel_layouts=$layout,volume=$(echo "$target - $measured" | bc -l)dB" "$@" "$out"
}
LN=$OUT/loudness
level "$LN/Level Album/01 Loud.flac" -8 stereo "sine=frequency=1000:duration=8:sample_rate=48000" $FLAC24 \
  -metadata title=Loud -metadata artist="Level Test" -metadata ALBUMARTIST="Level Test" -metadata album="Level Album" -metadata track=1
level "$LN/Level Album/02 Quiet.flac" -30 stereo "anoisesrc=color=pink:duration=8:sample_rate=48000:seed=11" $FLAC24 \
  -metadata title=Quiet -metadata artist="Level Test" -metadata ALBUMARTIST="Level Test" -metadata album="Level Album" -metadata track=2
level "$LN/Mid.flac" -20 stereo "anoisesrc=color=pink:duration=8:sample_rate=48000:seed=12" $FLAC24 -metadata title=Mid -metadata artist="Level Test"
level "$LN/Mono.flac" -20 mono "anoisesrc=color=pink:duration=8:sample_rate=48000:seed=14" $FLAC24 -metadata title=Mono -metadata artist="Level Test"
level "$OUT/peaky-noise.wav" -30 stereo "anoisesrc=color=pink:duration=8:sample_rate=48000:seed=13" -c:a pcm_f32le
ff -i "$OUT/peaky-noise.wav" -f lavfi -i "aevalsrc=exprs=if(eq(mod(n\,48000)\,24000)\,0.98\,0):s=48000:d=8:c=stereo" \
  -filter_complex "[0][1]amix=inputs=2:normalize=0" -c:a pcm_s24le "$LN/Peaky.wav"
rm "$OUT/peaky-noise.wav"
for part in 1 2; do
  trim=$([ $part = 1 ] && echo "atrim=end_sample=264601" || echo "atrim=start_sample=264601,volume=-6dB")
  mkdir -p "$LN/Step"
  ff -f lavfi -i "sine=frequency=375:sample_rate=48000:duration=12" -af "$trim" $FLAC24 \
    -metadata title="Step $part" -metadata artist="Test Tone" -metadata ALBUMARTIST="Test Tone" -metadata album=Step \
    -metadata track=$part/2 "$LN/Step/0$part Step $part.flac"
done

echo "$VERSION" > "$OUT/.version"
