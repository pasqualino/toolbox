#!/bin/zsh
# Checks for Compress Video (target size), Replace Audio (mix), Media Info and Extract Frames.
# Usage: CLI=<path to toolbox-cli> zsh Fixtures/batch1/check-media2.sh
set -u
ROOT=/Users/marcos/workspace/toolbox
CLI=${CLI:-$ROOT/.build/release/toolbox-cli}
F=$ROOT/Fixtures/media
OUT=$(mktemp -d)
pass=0; fail=0

check() { # check name ok|no detail
  if [[ "$2" == ok ]]; then echo "PASS $1 ${3:-}"; pass=$((pass+1)); else echo "FAIL $1 ${3:-}"; fail=$((fail+1)); fi
}
yes() { "$@" && echo ok || echo no; }
run() { # run <tool> args... ; prints the output paths, one per line
  local o; o=$("$CLI" "$@" --out "$OUT" 2>&1)
  echo "$o" | sed -n 's/^-> //p'
}
text() { "$CLI" "$@" --out "$OUT" 2>&1; }
bytes() { /usr/bin/stat -f%z "$1"; }
dur() { ffprobe -v error -show_entries format=duration -of csv=p=0 "$1"; }
size() { ffprobe -v error -select_streams v:0 -show_entries stream=width,height -of csv=p=0:s=x "$1"; }
astreams() { ffprobe -v error -select_streams a -show_entries stream=index -of csv=p=0 "$1" | wc -l | tr -d ' '; }
near() { awk -v a="$1" -v b="$2" -v t="${3:-0.15}" 'BEGIN{d=a-b; if(d<0)d=-d; exit !(d<=t)}'; }
plays() { ffmpeg -nostdin -v error -i "$1" -f null - 2>&1 | grep -q . && return 1 || return 0; }
meanvol() { ffmpeg -nostdin -hide_banner -ss "$2" -i "$1" -map 0:a:0 -af volumedetect -f null - 2>&1 | sed -n 's/.*mean_volume: \(.*\) dB/\1/p'; }
pixels() { sips -g pixelWidth -g pixelHeight "$1" | awk '/pixelWidth/{w=$2}/pixelHeight/{h=$2}END{print w"x"h}'; }

L=$F/landscape.mp4; S=$F/silent.mp4; P=$F/portrait_rotated.mov

# Compress Video: target size
for mb in 1 2; do
  o=$(run compress-video mode=size target=custom custommb=$mb $L | tail -1)
  b=$(bytes $o); limit=$((mb * 1000000))
  check "compress-size-${mb}MB" "$(yes test $b -le $limit -a $b -gt $((limit / 2)))" "$b bytes, $(size $o)"
  check "compress-size-${mb}MB-plays" "$(yes plays $o)" "$(dur $o)s"
done
o=$(run compress-video mode=size target=custom custommb=1 $L | tail -1); check compress-size-downscale-1MB "$(yes test "$(size $o)" = 854x480)" "$(size $o)"
o=$(run compress-video mode=size target=custom custommb=2 $L | tail -1); check compress-size-keeps-720p-2MB "$(yes test "$(size $o)" = 1280x720)" "$(size $o)"
o=$(run compress-video mode=size target=custom custommb=1.5 $P | tail -1); b=$(bytes $o)
check compress-size-portrait "$(yes test $b -le 1500000 -a "$(size $o)" = 720x1280)" "$b bytes, $(size $o)"
o=$(run compress-video mode=size target=custom custommb=0.4 $S | tail -1); b=$(bytes $o)
check compress-size-silent "$(yes test $b -le 400000 -a $b -gt 200000 -a "$(astreams $o)" = 0)" "$b bytes, audio streams $(astreams $o)"
o=$(run compress-video mode=size $L | tail -1); check compress-size-already-small-copies "$(yes cmp -s $o $L)" "${o:t}"
text compress-video mode=size $L | grep -q "^text: .*already under 10 MB" ; check compress-size-already-small-note "$([[ $? == 0 ]] && echo ok || echo no)"
text compress-video mode=size target=custom custommb=0.1 $L | grep -q "FAIL.*too small" ; check compress-size-impossible-error "$([[ $? == 0 ]] && echo ok || echo no)"
logs=(${TMPDIR:-/tmp}/Toolbox-2pass-*(N)); check compress-size-passlog-cleaned "$([[ ${#logs} == 0 ]] && echo ok || echo no)" "${#logs} left"

# Replace Audio: mix
o=$(run replace-audio audio=$F/short.wav mix=mix $L | tail -1)
check replace-mix-one-stream "$(yes test "$(astreams $o)" = 1)" "streams $(astreams $o)"
check replace-mix-duration "$(yes near "$(dur $o)" 10 0.15)" "$(dur $o)s"
# short.wav ends at 3 s: mixing keeps the original under it, replacing leaves silence.
v=$(meanvol $o 5); check replace-mix-keeps-original "$(yes awk -v v="$v" 'BEGIN{exit !(v > -50)}')" "${v} dB after the new audio ends"
r=$(run replace-audio audio=$F/short.wav $L | tail -1); v=$(meanvol $r 5)
check replace-plain-silent-after "$(yes awk -v v="$v" 'BEGIN{exit !(v < -80)}')" "${v} dB"
o=$(run replace-audio audio=$F/short.wav mix=mix fit=loop origvol=0 $L | tail -1)
check replace-mix-loop "$(yes test "$(astreams $o)" = 1)" "$(dur $o)s"
check replace-mix-loop-duration "$(yes near "$(dur $o)" 10 0.15)"
o=$(run replace-audio audio=$F/tone.mp3 mix=mix $S | tail -1)
check replace-mix-no-original-audio "$(yes test "$(astreams $o)" = 1)" "$(dur $o)s"
check replace-mix-no-original-duration "$(yes near "$(dur $o)" 6 0.15)"

# Media Info
has() { # has name output patterns...
  local name=$1 out=$2; shift 2; local missing=""
  for p in "$@"; do echo "$out" | grep -qE "$p" || missing="$missing [$p]"; done
  check "$name" "$([[ -z $missing ]] && echo ok || echo no)" "$missing"
}
t=$(text media-info $L); has info-mp4 "$t" "^text: File" "Name +landscape.mp4" "Duration +0:10" "Bitrate +3.20 Mbps" "Codec +H.264, High" "Resolution +1280 × 720" "Frame rate +30 fps" "Pixels +8-bit" "Codec +AAC" "Sample rate +48 kHz" "Read with +ffprobe"
t=$(text media-info $P); has info-mov-rotation "$t" "Rotation +90° counterclockwise" "shows as 1080 × 1920" "Aspect +9:16"
t=$(text media-info $F/tone.mp3); has info-mp3 "$t" "Codec +MP3" "Duration +0:12" "Sample rate +44.1 kHz" "Bitrate +192 kbps"
t=$(text media-info $F/tone.wav); has info-wav "$t" "Codec +PCM 16-bit" "Channels +2" "Duration +0:07"
t=$(text media-info $ROOT/Fixtures/photo.jpg); has info-jpg "$t" "Dimensions +1920 × 1080" "Color model +RGB" "Bit depth +8" "Read with +ImageIO"
t=$(text media-info $ROOT/Fixtures/photo.heic); has info-heic "$t" "Format +HEIF" "Dimensions +1920 × 1080"
t=$(text media-info $ROOT/Fixtures/images/gps.heic); has info-gps "$t" "GPS +38.72000, -9.14000" "Make +Apple" "Model +iPhone 99" "Lens +Test Lens" "Date taken"
t=$(TOOLBOX_MEDIAINFO_AVFOUNDATION=1 text media-info $P); has info-avfoundation-fallback "$t" "Read with +AVFoundation" "Codec +H.264" "Rotation +90° counterclockwise" "Sample rate +44.1 kHz"
t=$(text media-info $L $F/tone.mp3); has info-multiple "$t" "Name +landscape.mp4" "Name +tone.mp3"
t=$(text media-info $L); check info-no-files "$(echo "$t" | grep -q '^-> ' && echo no || echo ok)"

# Extract Frames
count() { run extract-frames "$@" | grep -c '\.\(png\|jpg\|heic\)$'; }
check frames-count-default "$(yes test "$(count $L)" = 10)"
check frames-count-range "$(yes test "$(count count=4 range=2-6 $L)" = 4)"
check frames-interval "$(yes test "$(count mode=interval seconds=2 $L)" = 5)"
check frames-interval-range "$(yes test "$(count mode=interval seconds=0.5 range=1-3 $L)" = 4)"
o=$(run extract-frames mode=times times="0:01, 5.5, 9.99" $L)
check frames-times "$(yes test "$(echo "$o" | wc -l | tr -d ' ')" = 3)" "$(echo "$o" | xargs -I{} basename {} | tr '\n' '|')"
check frames-times-names "$(echo "$o" | grep -q 'landscape frames/landscape 0002 (00m05.5s).png' && echo ok || echo no)"
text extract-frames mode=times times="0:30" $L | grep -q "FAIL.*past the end"; check frames-times-past-end-error "$([[ $? == 0 ]] && echo ok || echo no)"
text extract-frames mode=times times="abc" $L | grep -q "FAIL.*Couldn't read"; check frames-times-bad-error "$([[ $? == 0 ]] && echo ok || echo no)"
text extract-frames count=1001 $L | grep -q "FAIL.*1001 frames.*1000 limit"; check frames-cap-error "$([[ $? == 0 ]] && echo ok || echo no)"
SC=$OUT/scenes.mp4
ffmpeg -nostdin -v error -f lavfi -i "color=red:s=320x240:d=2:r=25" -f lavfi -i "color=blue:s=320x240:d=2:r=25" \
  -f lavfi -i "color=green:s=320x240:d=2:r=25" -filter_complex "[0][1][2]concat=n=3:v=1" -pix_fmt yuv420p $SC
o=$(run extract-frames mode=scenes $SC)
check frames-scenes "$(yes test "$(echo "$o" | wc -l | tr -d ' ')" = 3)" "$(echo "$o" | xargs -I{} basename {} | tr '\n' '|')"
check frames-scenes-times "$(echo "$o" | grep -q '(00m02s)' && echo "$o" | grep -q '(00m04s)' && echo ok || echo no)"
check frames-scenes-range "$(yes test "$(count mode=scenes range=1-5 $SC)" = 3)"
o=$(run extract-frames count=2 $P | tail -1); check frames-portrait "$(yes test "$(pixels $o)" = 1080x1920)" "$(pixels $o)"
o=$(run extract-frames count=3 format=heic $L | tail -1)
check frames-heic "$(yes test "${o:e}" = heic -a "$(pixels $o)" = 1280x720)" "${o:t} $(sips -g format $o | awk '/format/{print $2}')"
o=$(run extract-frames count=2 format=jpeg $P | tail -1)
check frames-jpeg-portrait "$(yes test "${o:e}" = jpg -a "$(pixels $o)" = 1080x1920)" "${o:t}"

echo "$pass passed, $fail failed. Outputs in $OUT"
[[ $fail == 0 ]]
