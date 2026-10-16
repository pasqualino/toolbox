#!/bin/zsh
# Checks for Beautify Screenshot, Redact Image, Remove Background fill, Make/Read QR Code and Add Password permissions.
# Usage: CLI=path/to/toolbox-cli zsh Fixtures/batch1/check-img2.sh
set -u
ROOT=/Users/marcos/workspace/toolbox
CLI=${CLI:-$ROOT/.build/release/toolbox-cli}
F=$ROOT/Fixtures
B=$F/batch1
OUT=$(mktemp -d)
pass=0; fail=0

run() { "$CLI" "$@" --out "$OUT" 2>&1 | sed -n 's/^-> //p'; }
first() { run "$@" | head -1; }
all() { "$CLI" "$@" --out "$OUT" 2>&1; }
textout() { "$CLI" "$@" --out "$OUT" 2>&1 | awk '/^text: /{on=1; sub(/^text: /,"")} /^(ok   |FAIL |-> )/{on=0} on'; }
check() { if [[ "$2" == ok ]]; then echo "PASS $1 ${3:-}"; pass=$((pass+1)); else echo "FAIL $1 ${3:-}"; fail=$((fail+1)); fi; }
is() { [[ "$1" == "$2" ]] && echo ok || echo no; }
has() { grep -qF -- "$2" <<< "$1" && echo ok || echo no; }
hasnt() { grep -qF -- "$2" <<< "$1" && echo no || echo ok; }
dims() { sips -g pixelWidth -g pixelHeight "$1" 2>/dev/null | awk '/pixel/{print $2}' | paste -sd x -; }
alpha() { sips -g hasAlpha "$1" 2>/dev/null | awk '/hasAlpha/{print $2}'; }

# Pixel helper: "px FILE X Y" prints r,g,b,a (top-left origin); "diff A B Y0 Y1" counts differing pixels in a row band;
# "perm PDF PASSWORD" prints locked,printing,copying after unlocking.
cat > $OUT/helper.swift <<'SWIFT'
import Foundation
import ImageIO
import PDFKit
func rgba(_ p: String) -> (CGContext, UnsafeMutablePointer<UInt8>) {
    let s = CGImageSourceCreateWithURL(URL(fileURLWithPath: p) as CFURL, nil)!
    let i = CGImageSourceCreateImageAtIndex(s, 0, nil)!
    let c = CGContext(data: nil, width: i.width, height: i.height, bitsPerComponent: 8, bytesPerRow: i.width * 4,
                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    c.draw(i, in: CGRect(x: 0, y: 0, width: i.width, height: i.height))
    return (c, c.data!.assumingMemoryBound(to: UInt8.self))
}
let a = CommandLine.arguments
switch a[1] {
case "px":
    let (c, b) = rgba(a[2]); let o = Int(a[4])! * c.bytesPerRow + Int(a[3])! * 4
    print("\(b[o]),\(b[o+1]),\(b[o+2]),\(b[o+3])")
case "diff":
    let (c1, b1) = rgba(a[2]); let (c2, b2) = rgba(a[3]); var n = 0
    for y in Int(a[4])!..<Int(a[5])! { for x in 0..<c1.width * 4 where b1[y * c1.bytesPerRow + x] != b2[y * c1.bytesPerRow + x] { n += 1 } }
    withExtendedLifetime((c1, c2)) { print(n) }
case "perm":
    let d = PDFDocument(url: URL(fileURLWithPath: a[2]))!
    let locked = d.isLocked; _ = d.unlock(withPassword: a[3])
    print("\(locked),\(d.allowsPrinting),\(d.allowsCopying)")
default: break
}
SWIFT
swiftc -O -o $OUT/helper $OUT/helper.swift 2>/dev/null || { echo "FAIL helper build"; exit 1; }
H=$OUT/helper

# Beautify Screenshot. margins.png: 800x600 with a 600x400 opaque window inside a soft shadow ring.
o=$(first beautify-screenshot $B/margins.png); check beautify-trim-padding "$(is "$(dims $o)" 696x496)" "$(dims $o)"
check beautify-name "$(is "${o:t}" "margins beautified.png")" "${o:t}"
check beautify-opaque "$(is "$(alpha $o)" no)"
check beautify-gradient-corner "$([[ "$($H px $o 2 2)" != "255,255,255,255" && "$($H px $o 2 2)" == *,255 ]] && echo ok)" "$($H px $o 2 2)"
o=$(first beautify-screenshot ratio=16:9 $B/margins.png); check beautify-16x9 "$(is "$(dims $o)" 882x496)"
o=$(first beautify-screenshot ratio=4:3 $B/margins.png); check beautify-4x3 "$(is "$(dims $o)" 696x522)"
o=$(first beautify-screenshot ratio=1:1 padding=0 $B/margins.png); check beautify-1x1 "$(is "$(dims $o)" 600x600)"
o=$(first beautify-screenshot padding=0 shadow=false radius=0 $B/margins.png); check beautify-trim-only "$(is "$(dims $o)" 600x400)"
o=$(first beautify-screenshot background=transparent $B/margins.png)
check beautify-transparent "$(is "$(alpha $o)" yes)"; check beautify-transparent-corner "$(is "$($H px $o 1 1)" 0,0,0,0)"
o=$(first beautify-screenshot $F/photo.jpg); check beautify-opaque-input "$(is "$(dims $o)" 2228x1388)"
o=$(first beautify-screenshot background=white radius=0 shadow=false $F/photo.png)
check beautify-white "$(is "$($H px $o 3 3)" 255,255,255,255)"
# No resampling: the screenshot's pixels are copied 1:1 at the padding offset (pad 154 for 1920 px).
check beautify-no-resample "$(is "$($H px $o 400 400)" "$($H px $F/photo.png 246 246)")"

# Redact Image. redact-text.png: line i spans y 40+70i..+50.
R=$B/redact-text.png
t=$(textout extract-text $R)
for s in AKIA 4242 example.com eyJ 192.168 "quick brown"; do check redact-input-has "$(has "$t" $s)" "$s"; done
o=$(first redact-image $R); check redact-name "$(is "${o:t}" "redact-text redacted.png")" "${o:t}"
t=$(textout extract-text $o)
for s in AKIA IOSFODNN 4242 jane.doe eyJ dBjft Zk9pQ2xLm7Rt; do check redact-removed "$(hasnt "$t" $s)" "$s"; done
for s in "quick brown fox" "Normal words stay readable" "AWS key" "in config" "192.168.10.42" \
         "getting-started-2024" "workspace/toolbox1" "monkey = 3"; do check redact-kept "$(has "$t" $s)" "$s"; done
check redact-fill-black "$(is "$($H px $o 360 275)" 0,0,0,255)" "AWS key pixel"
check redact-normal-line-untouched "$(is "$($H diff $R $o 40 90)" 0)" "line 0"
check redact-normal-line6-untouched "$(is "$($H diff $R $o 460 510)" 0)" "line 6"
t=$(textout extract-text $(first redact-image ips=true $R)); check redact-ips "$(hasnt "$t" 192.168)"
p=$(first redact-image style=pixelate $R); b=$(first redact-image style=blur $R)
px=$($H px $p 360 275); bx=$($H px $b 360 275)
check redact-pixelate "$([[ $px != 0,0,0,255 && $px != 255,255,255,255 ]] && echo ok)" "$px"
check redact-blur "$([[ $bx != 0,0,0,255 && $bx != $px ]] && echo ok)" "$bx"
check redact-styles-differ "$([[ $(md5 -q $o) != $(md5 -q $p) && $(md5 -q $p) != $(md5 -q $b) ]] && echo ok)"
for f in $p $b; do t=$(textout extract-text $f); check "redact-${f:t:r}-unreadable" "$([[ $(hasnt "$t" AKIA) == ok && $(hasnt "$t" 4242) == ok ]] && echo ok)"; done
# Regions only, on a GPS-tagged PNG: region is black, metadata gone. 1920x1080: region center at (768, 432).
o=$(first redact-image faces=false emails=false secrets=false cards=false regions=0.3,0.3,0.2,0.2 $F/images/gps.png)
check redact-region-black "$(is "$($H px $o 768 432)" 0,0,0,255)"
check redact-outside-region "$(is "$($H px $o 100 100)" "$($H px $F/images/gps.png 100 100)")"
check redact-strips-gps "$(mdls -raw -name kMDItemLatitude $o | grep -q null && echo ok)"
o=$(first redact-image faces=false regions=0,0,0.5,0.5 $F/photo.jpg); check redact-jpeg-stays-jpeg "$(is "${o:e}" jpg)" "${o:t}"
check redact-nothing-found "$(has "$(all redact-image $B/margins.png)" "Found nothing to redact")"

# Remove Background fill
S=$F/images/subject.jpg
o=$(first remove-background $S); check removebg-default-alpha "$(is "$(alpha $o)" yes)"
o=$(first remove-background fill=white $S); check removebg-white "$(is "$($H px $o 2 2)" 255,255,255,255)" "$(alpha $o)"
check removebg-white-png "$([[ ${o:e} == png && $(alpha $o) == no ]] && echo ok)"
o=$(first remove-background fill=black $S); check removebg-black "$(is "$($H px $o 2 2)" 0,0,0,255)"
o=$(first remove-background fill=custom color=#FF0000 $S); check removebg-custom "$(is "$($H px $o 2 2)" 255,0,0,255)"
check removebg-bad-color "$(has "$(all remove-background fill=custom color=nope $S)" "Enter a color")"

# Make QR Code and Read QR Code
o=$(first make-qr --text "hello world"); check make-qr-name "$(is "${o:t}" "QR hello world.png")"
d=$(dims $o); check make-qr-size "$([[ ${d%x*} == ${d#*x} && ${d%x*} -ge 900 && ${d%x*} -le 1150 ]] && echo ok)" "$d"
check read-qr-text "$(is "$(textout read-qr $o)" "hello world")"
u="https://example.com/path?q=1&x=y"
o=$(first make-qr correction=H size=2048 --text "$u"); check make-qr-url-name "$(is "${o:t}" "QR example.com path?q=1&x=y.png")" "${o:t}"
check read-qr-url "$(is "$(textout read-qr $o)" "$u")"
o=$(first make-qr type=wifi ssid='Café;Net:"1"' password='p\a;s,s:"w' hidden=true)
# Compared loosely: the path comes back with a decomposed é.
check make-qr-wifi-name "$([[ ${o:t} == Wi-Fi\ Caf*\;Net\ \"1\".png ]] && echo ok)" "${o:t}"
t=$(textout read-qr $o)
check read-qr-wifi-network "$(has "$t" 'Network: Café;Net:"1"')"; check read-qr-wifi-password "$(has "$t" 'Password: p\a;s,s:"w')"
check read-qr-wifi-security "$(has "$t" 'Security: WPA')"; check read-qr-wifi-hidden "$(has "$t" 'Hidden: yes')"
o=$(first make-qr type=wifi ssid=Guest security=none); check read-qr-wifi-open "$(has "$(textout read-qr $o)" "Security: None")"
print -n "from a file" > $OUT/qr.txt; o=$(first make-qr $OUT/qr.txt); check make-qr-from-file "$(is "$(textout read-qr $o)" "from a file")"
o=$(first make-qr margin=false size=512 correction=L --text hi); check make-qr-no-margin "$(is "$(dims $o)" 504x504)" "21 modules x 24"
check make-qr-empty "$(has "$(all make-qr)" "Enter text")"
check make-qr-no-ssid "$(has "$(all make-qr type=wifi)" "network name")"
check make-qr-too-long "$(has "$(all make-qr --text "$(printf 'x%.0s' {1..4000})")" "Too much text")"
q=$(first make-qr --text "in a pdf"); pdf=$(first images-to-pdf $q $F/photo.png)
check read-qr-pdf "$(is "$(textout read-qr $pdf)" "in a pdf")"
check read-qr-none "$(has "$(all read-qr $F/photo.jpg)" "No QR code")"

# Add Password permissions
P=$F/pdf/two.pdf
o=$(first protect-pdf password=pw $P); check protect-default-perms "$(is "$($H perm $o pw)" true,true,true)"
o=$(first protect-pdf password=pw print=false $P); check protect-no-print "$(is "$($H perm $o pw)" true,false,true)"
o=$(first protect-pdf password=pw copy=false $P); check protect-no-copy "$(is "$($H perm $o pw)" true,true,false)"
o=$(first protect-pdf password=pw print=false copy=false $P); check protect-no-both "$(is "$($H perm $o pw)" true,false,false)"

echo "$pass passed, $fail failed"
rm -rf "$OUT"
[[ $fail -eq 0 ]]
