#!/bin/zsh
# Release-build smoke checks for image, PDF, AI, file and download tools. Usage: Fixtures/check-other.sh
set -u
ROOT=/Users/marcos/workspace/toolbox
CLI=${CLI:-$ROOT/.build/release/toolbox-cli}
F=$ROOT/Fixtures
OUT=$(mktemp -d)
pass=0; fail=0

run() { "$CLI" "$@" --out "$OUT" 2>&1 | sed -n 's/^-> //p'; }
first() { run "$@" | head -1; }
# Text-only tools print their result as "text: ..." and save nothing.
textout() { "$CLI" "$@" --out "$OUT" 2>&1 | awk '/^text: /{on=1; sub(/^text: /,"")} /^(ok   |FAIL |-> )/{on=0} on'; }
nofile() { [[ -z "$("$CLI" "$@" --out "$OUT" 2>&1 | sed -n 's/^-> //p')" ]] && echo ok || echo no; }
check() { if [[ "$2" == ok ]]; then echo "PASS $1 ${3:-}"; pass=$((pass+1)); else echo "FAIL $1 ${3:-}"; fail=$((fail+1)); fi; }
is() { [[ "$1" == "$2" ]] && echo ok || echo no; }
dims() { sips -g pixelWidth -g pixelHeight "$1" 2>/dev/null | awk '/pixel/{print $2}' | paste -sd x -; }
pages() { swift -e 'import PDFKit; print(PDFDocument(url: URL(fileURLWithPath: CommandLine.arguments[1]))!.pageCount)' "$1" 2>/dev/null; }
pdftext() { swift -e 'import PDFKit; let d = PDFDocument(url: URL(fileURLWithPath: CommandLine.arguments[1]))!; print((0..<d.pageCount).map { d.page(at: $0)!.string ?? "" }.joined(separator: "|"))' "$1" 2>/dev/null | tr -d '\n'; }
locked() { swift -e 'import PDFKit; print(PDFDocument(url: URL(fileURLWithPath: CommandLine.arguments[1]))!.isLocked)' "$1" 2>/dev/null; }

# Images
o=$(first convert-images format=png $F/photo.jpg); check convert-images "$(is "$(dims $o)" 1920x1080)" "${o:t}"
o=$(first convert-images format=webp $F/photo.heic); check convert-webp "$(is "${o:e}" webp)" "$(/usr/bin/stat -f%z $o)B"
o=$(first compress-images $F/images/subject.jpg); check compress-images "$([[ $(/usr/bin/stat -f%z $o) -lt $(/usr/bin/stat -f%z $F/images/subject.jpg) ]] && echo ok)" "$(/usr/bin/stat -f%z $o)B"
o=$(first resize-images mode=width size=800 $F/photo.png); check resize-images "$(is "$(dims $o)" 800x450)"
o=$(first rotate-images turn=right $F/photo.png); check rotate-images "$(is "$(dims $o)" 1080x1920)"
o=$(first remove-background $F/images/subject.jpg); check remove-background "$(is "$(sips -g hasAlpha $o | awk '/hasAlpha/{print $2}')" yes)" "${o:t}"
o=$(first remove-metadata $F/images/gps.heic); check remove-metadata "$( mdls -raw -name kMDItemLatitude $o | grep -q null && echo ok)"
n=$(run batch-rename pattern='Trip {n}' $F/photo.png $F/photo.jpg | xargs -I{} basename {} | paste -sd , -); check batch-rename "$(is "$n" "Trip 1.png,Trip 2.jpg")" "$n"

# PDF
P=$F/pdf
o=$(first merge-pdf $P/six.pdf $P/two.pdf); check merge-pdf "$(is "$(pages $o)" 8)"
c=$(run split-pdf $P/six.pdf | wc -l | tr -d ' '); check split-pdf "$(is "$c" 6)"
o=$(first organize-pdf pages=3,1,2 $P/six.pdf); check organize-pdf "$(pdftext $o | grep -q '^Page 3|Page 1|Page 2' && echo ok)" "$(pages $o) pages"
o=$(first delete-pdf-pages pages=2,4-5 $P/six.pdf); check delete-pdf-pages "$(is "$(pages $o)" 3)"
o=$(first extract-pdf-pages pages=2-3 $P/six.pdf); check extract-pdf-pages "$(is "$(pages $o)" 2)"
o=$(first protect-pdf password=hunter2 $P/two.pdf); check protect-pdf "$(is "$(locked $o)" true)"
o=$(first unlock-pdf password=secret $P/locked.pdf); check unlock-pdf "$(is "$(locked $o)" false)"
o=$(first images-to-pdf $F/photo.png $F/photo.jpg); check images-to-pdf "$(is "$(pages $o)" 2)"
c=$(run pdf-to-images $P/two.pdf | wc -l | tr -d ' '); check pdf-to-images "$(is "$c" 2)"

# AI
A=$F/ai
t=$(textout transcribe $A/speech.m4a); check transcribe "$(grep -qi 'fox' <<< "$t" && echo ok)" "${t:0:60}"
check transcribe-no-file "$(nofile transcribe $A/speech.m4a)"
o=$(first transcribe format=srt $A/speech.mp4); check transcribe-srt "$(grep -q -- '-->' $o && echo ok)"
t=$(textout extract-text $A/scanned.pdf); check extract-text "$([[ -n "$t" ]] && echo ok)" "${t:0:50}"
check extract-text-no-file "$(nofile extract-text $A/text-image.png)"
# Summarize: real summary when Apple Intelligence is on, clear error when it's off.
if "$CLI" summarize --text "Hello world" --out "$OUT" 2>&1 | grep -q "Apple Intelligence"; then
  check summarize-unavailable ok "clear error"
else
  t=$(textout summarize $A/article.txt); check summarize "$(grep -qi 'train' <<< "$t" && echo ok)" "${t:0:70}"
  check summarize-no-file "$(nofile summarize $A/article.txt)"
  "$CLI" summarize --text "Hello world" --out "$OUT" 2>&1 | grep -q "too short" && check summarize-short ok || check summarize-short no
fi
"$CLI" translate --text "Hello world" --out "$OUT" 2>&1 | grep -qE "Translation Languages|aren't downloaded" && check translate-missing-langs ok "clear error" || check translate-missing-langs no

# Download (network)
o=$(first download-video --text "https://test-videos.co.uk/vids/bigbuckbunny/mp4/h264/360/Big_Buck_Bunny_360_10s_1MB.mp4" quality=best); check download-video "$([[ -s $o ]] && echo ok)" "${o:t}"

echo "$pass passed, $fail failed. Outputs in $OUT"
