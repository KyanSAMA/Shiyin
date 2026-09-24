#!/bin/bash
# Generate the deterministic self-test library in .build/fixtures (skipped when already current).
# Requires ffmpeg and metaflac. Layout:
#   library/   11 playable files across FLAC 44.1/96/192 kHz, ID3v2.3/2.4 MP3, ALAC M4A, WAV, untagged, sidecar LRC,
#              and a gapless pair (one 375 Hz tone split mid-buffer, 12 s = whole periods)
#   library/Music/  a file the self-tests exclude;  library/junk/  non-audio files the scanner must ignore
#   extra/     files copied in at runtime to exercise FSEvents
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION=3
OUT=.build/fixtures
[ "$(cat "$OUT/.version" 2>/dev/null)" = "$VERSION" ] && exit 0
rm -rf "$OUT"
mkdir -p "$OUT"
LIB=$OUT/library

ff() { ffmpeg -v error -y "$@"; }

ff -f lavfi -i "color=c=0x2f5aa8:s=600x600,drawbox=x=100:y=100:w=400:h=400:color=0xf2c14e:t=fill" -frames:v 1 "$OUT/cover-a.png"
ff -f lavfi -i "color=c=0x8a2be2:s=600x600,drawbox=x=0:y=300:w=600:h=300:color=0x20b2aa:t=fill" -frames:v 1 "$OUT/cover-b.png"

# audio <out> <seconds> <rate> <codec args> <cover.png|-> [ffmpeg metadata args...]
audio() {
  local out=$1 seconds=$2 rate=$3 codec=$4 cover=$5
  shift 5
  mkdir -p "$(dirname "$out")"
  local source=(-f lavfi -i "sine=frequency=440:duration=$seconds:sample_rate=$rate")
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
audio "$LIB/sidecar/歌.flac" 3 44100 "$FLAC16" -
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

audio "$OUT/extra/新歌.flac" 2 44100 "$FLAC16" - -metadata title=新歌 -metadata artist=YOASOBI

echo "$VERSION" > "$OUT/.version"
