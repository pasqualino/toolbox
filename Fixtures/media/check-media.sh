#!/bin/zsh
# Headless checks for the video and audio tools. Usage: Fixtures/media/check-media.sh
set -u
ROOT=/Users/marcos/workspace/toolbox
CLI=${CLI:-$ROOT/.build/release/toolbox-cli}
F=$ROOT/Fixtures/media
OUT=$(mktemp -d)
pass=0; fail=0

run() { # run <tool> args... ; prints the single output path
  local o; o=$("$CLI" "$@" --out "$OUT" 2>&1); local rc=$?
  if [[ $rc -ne 0 ]]; then echo "   CLI failed: $o" >&2; echo ""; return; fi
  echo "$o" | sed -n 's/^-> //p' | tail -1
}
dur() { ffprobe -v error -show_entries format=duration -of csv=p=0 "$1"; }
size() { ffprobe -v error -select_streams v:0 -show_entries stream=width,height -of csv=p=0:s=x "$1"; }
vcodec() { ffprobe -v error -select_streams v:0 -show_entries stream=codec_name -of csv=p=0 "$1"; }
acodec() { ffprobe -v error -select_streams a:0 -show_entries stream=codec_name -of csv=p=0 "$1"; }
frames() { ffprobe -v error -count_frames -select_streams v:0 -show_entries stream=nb_read_frames -of csv=p=0 "$1"; }
near() { awk -v a="$1" -v b="$2" -v t="${3:-0.15}" 'BEGIN{d=a-b; if(d<0)d=-d; exit !(d<=t)}'; }
check() { # check name condition-result
  if [[ "$2" == ok ]]; then echo "PASS $1 ${3:-}"; pass=$((pass+1)); else echo "FAIL $1 ${3:-}"; fail=$((fail+1)); fi
}
is() { [[ "$1" == "$2" ]] && echo ok || echo no; }
nr() { near "$@" && echo ok || echo no; }

L=$F/landscape.mp4; S=$F/silent.mp4; P=$F/portrait_rotated.mov; O=$F/odd.mkv

o=$(run compress-video $L); check compress-default "$(is "$(vcodec $o)/$(acodec $o)/$(size $o)" h264/aac/1280x720)" "$(vcodec $o) $(size $o) $(dur $o)s $(/usr/bin/stat -f%z $L)->$(/usr/bin/stat -f%z $o)B"
o=$(run compress-video size=720 hevc=true quality=small $P); check compress-hevc-portrait "$(is "$(vcodec $o)/$(size $o)" hevc/720x1280)" "$(size $o) $(ffprobe -v error -select_streams v:0 -show_entries stream=codec_tag_string -of csv=p=0 $o)"
o=$(run compress-video $O); check compress-odd-mkv "$(is "$(size $o)" 720x1278)" "$(size $o)"

o=$(run convert-video $O); check convert-mp4 "$(is "$(vcodec $o)/$(acodec $o)/${o:e}" h264/aac/mp4)" "$o:t"
o=$(run convert-video format=mov $L); check convert-mov "$(is "$(vcodec $o)/${o:e}" h264/mov)"
o=$(run convert-video format=webm $L); check convert-webm "$(is "$(vcodec $o)/$(acodec $o)" vp9/opus)" "$(dur $o)s"
o=$(run convert-video format=hevc $S); check convert-hevc-silent "$(is "$(vcodec $o)/$(acodec $o)" hevc/)"

o=$(run trim-video range=2-5.5 $L); check trim-accurate "$(nr $(dur $o) 3.5 0.1)" "$(dur $o)s $o:t"
o=$(run trim-video range=2-5.5 fast=true $L); check trim-fast "$(nr $(dur $o) 3.5 2.1)" "$(dur $o)s $(acodec $o)"
o=$(run trim-video $P); check trim-default-whole-portrait "$(is "$(size $o)" 1080x1920)" "$(size $o) $(dur $o)s"
"$CLI" trim-video range=3-3 --out $OUT $L | grep -q "FAIL.*empty" && check trim-empty-error ok || check trim-empty-error no

o=$(run resize-video $L); check resize-1080-no-upscale "$(is "$(size $o)" 1280x720)"
abr() { ffprobe -v error -select_streams a:0 -show_entries stream=bit_rate -of csv=p=0 "$1"; }
o=$(run resize-video size=720 $L); check resize-copies-audio "$(is "$(abr $o)" "$(abr $L)")" "$(abr $L)->$(abr $o)"
o=$(run resize-video size=480 $P); check resize-480-portrait "$(is "$(size $o)" 480x854)" "$(size $o)"
o=$(run resize-video size=1080 upscale=true $L); check resize-upscale "$(is "$(size $o)" 1920x1080)"
o=$(run resize-video size=custom width=500 height=500 $L); check resize-custom-box "$(is "$(size $o)" 500x282)" "$(size $o)"
o=$(run resize-video size=custom width=0 height=301 $O); check resize-custom-odd "$(size $o | awk -Fx '{print ($1%2==0 && $2%2==0)?"ok":"no"}')" "$(size $o)"

o=$(run crop-rotate-video aspect=1:1 $L); check crop-square "$(is "$(size $o)" 720x720)"
o=$(run crop-rotate-video aspect=9:16 $L); check crop-9:16 "$(is "$(size $o)" 404x720)" "$(size $o)"
o=$(run crop-rotate-video rotate=right $L); check rotate-right "$(is "$(size $o)" 720x1280)"
o=$(run crop-rotate-video rotate=180 fliph=true aspect=4:5 $P); check rotate180-flip-4:5-portrait "$(is "$(size $o)" 1080x1350)" "$(size $o)"
"$CLI" crop-rotate-video --out $OUT $L | grep -q FAIL && check crop-nothing-error ok || check crop-nothing-error no

o=$(run change-video-speed $L); check speed-2x "$(nr $(dur $o) 5 0.15)" "$(dur $o)s $(acodec $o)"
o=$(run change-video-speed speed=0.25 $L); check speed-0.25x "$(nr $(dur $o) 40 0.3)" "$(dur $o)s"
o=$(run change-video-speed speed=3 $S); check speed-3x-silent "$(nr $(dur $o) 2 0.15)" "$(dur $o)s audio=[$(acodec $o)]"

o=$(run merge-videos $L $S $P); check merge "$(is "$(size $o)/$(acodec $o)" 1280x720/aac)" "$(size $o) $(dur $o)s (expect 21)"
check merge-duration "$(nr $(dur $o) 21 0.2)"
o=$(run merge-videos $S $S); check merge-no-audio "$(is "$(acodec $o)" "")" "$(dur $o)s"

o=$(run mute-video $L); check mute "$(is "$(vcodec $o)/$(acodec $o)" h264/)" "$o:t"
o=$(run mute-video $P); check mute-keeps-rotation "$(ffprobe -v error -select_streams v:0 -show_entries stream_side_data=rotation -of csv=p=0 $o | grep -q 90 && echo ok)"

o=$(run replace-audio audio=$F/short.wav $L); check replace-trim "$(nr $(dur $o) 10 0.15)" "$(dur $o)s $(acodec $o)"
o=$(run replace-audio audio=$F/short.wav fit=loop $L); check replace-loop "$(nr $(dur $o) 10 0.15)" "$(dur $o)s"
o=$(run replace-audio audio=$F/tone.mp3 $S); check replace-longer-audio "$(nr $(dur $o) 6 0.15)" "$(dur $o)s"
"$CLI" replace-audio --out $OUT $L | grep -q "FAIL.*Choose" && check replace-no-audio-error ok || check replace-no-audio-error no

o=$(run video-to-gif $L); check gif-default "$(is "$(size $o)/$(frames $o)" 480x270/150)" "$(size $o) $(frames $o) frames"
o=$(run video-to-gif range=1-3 fps=10 width=original $P); check gif-range-portrait "$(is "$(size $o)/$(frames $o)" 1080x1920/20)" "$(size $o) $(frames $o) frames"

o=$(run trim-audio range=1-4 $F/tone.mp3); check trim-mp3 "$(nr $(dur $o) 3 0.1)" "$(dur $o)s $(acodec $o) ${o:e}"
o=$(run trim-audio range=0.5-2 $F/tone.wav); check trim-wav "$(nr $(dur $o) 1.5 0.01)" "$(dur $o)s $(acodec $o)"

o=$(run extract-audio $L); check extract-m4a-copy "$(is "$(acodec $o)/${o:e}" aac/m4a)" "$(dur $o)s"
o=$(run extract-audio format=mp3 $P); check extract-mp3 "$(is "$(acodec $o)" mp3)"
o=$(run extract-audio format=flac $L); check extract-flac "$(is "$(acodec $o)" flac)"
o=$(run extract-audio format=wav $O); check extract-wav "$(is "$(acodec $o)" pcm_s16le)"
"$CLI" extract-audio --out $OUT $S | grep -q "FAIL.*no sound" && check extract-no-audio-error ok || check extract-no-audio-error no

o=$(run convert-audio $F/tone.mp3); check convert-m4a "$(is "$(acodec $o)/${o:e}" aac/m4a)" "$(ffprobe -v error -show_entries format=bit_rate -of csv=p=0 $o)bps"
o=$(run convert-audio format=mp3 bitrate=320 $F/tone.wav); check convert-mp3-320 "$(is "$(acodec $o)" mp3)" "$(ffprobe -v error -show_entries format=bit_rate -of csv=p=0 $o)bps"
o=$(run convert-audio format=flac $F/tone.mp3); check convert-flac "$(is "$(acodec $o)" flac)"
o=$(run convert-audio format=aiff $F/tone.mp3); check convert-aiff "$(is "$(acodec $o)/${o:e}" pcm_s16be/aiff)"
o=$(run convert-audio format=wav $F/tone.mp3); check convert-wav "$(nr $(dur $o) 12 0.1)"

echo "$pass passed, $fail failed. Outputs in $OUT"
