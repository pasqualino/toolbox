#!/bin/zsh
# Checks for Capture Text, Keep Awake, Network Speed Test and Fix "App Is Damaged". Usage: Fixtures/batch1/check-mac.sh
# Needs a network connection (speed test, ~25 s). Screen Recording may be off for the terminal; both outcomes pass.
set -u
ROOT=/Users/marcos/workspace/toolbox
CLI=${CLI:-$ROOT/.build/release/toolbox-cli}
F=$ROOT/Fixtures
OUT=$(mktemp -d)
TMP=$(mktemp -d)
trap 'rm -rf "$OUT" "$TMP"' EXIT
pass=0; fail=0

check() { if [[ "$2" == ok ]]; then echo "PASS $1 ${3:-}"; pass=$((pass+1)); else echo "FAIL $1 ${3:-}"; fail=$((fail+1)); fi; }
skip() { echo "SKIP $1 ${2:-}"; }
# Text-only tools print their result as "text: ..." and save nothing.
textout() { "$CLI" "$@" --out "$OUT" 2>&1 | awk '/^text: /{on=1; sub(/^text: /,"")} /^(ok   |FAIL |-> )/{on=0} on'; }
failout() { "$CLI" "$@" --out "$OUT" 2>&1 | sed -n 's/^FAIL \[0\] //p'; }
has() { grep -qF -- "$2" <<< "$1" && echo ok || echo no; }
assertions() { pmset -g assertions | grep -c 'Toolbox Keep Awake'; }

# Listing
l=$("$CLI" layout); check layout "$( [[ $l != *MISSING* ]] && grep -q 'Capture Text' <<< "$l" && grep -q 'Keep Awake' <<< "$l" && grep -q 'Network Speed Test' <<< "$l" && grep -q 'App Is Damaged' <<< "$l" && echo ok)"

# Capture Text
t=$(textout capture-text file=$F/ai/text-image.png); check capture-file "$(has "$t" "quick brown fox")" "${t:0:40}"
t=$(textout capture-text file=$F/ai/text-image.png lines=join); check capture-join "$( [[ $(wc -l <<< "$t" | tr -d ' ') == 1 ]] && grep -q fox <<< "$t" && echo ok)"
e=$(failout capture-text region=1,2); check capture-bad-region "$(has "$e" "Region must be x,y,w,h")"
r=$("$CLI" capture-text region=0,0,400,120 --out "$OUT" 2>&1)
if grep -q 'Screen Recording permission' <<< "$r"; then
    check capture-region-permission ok "(Screen Recording off for this terminal: permission message shown)"
else
    check capture-region "$(grep -qE '^(text: |FAIL \[0\] No text found)' <<< "$r" && echo ok)" "${r:0:60}"
fi
n=$(ls "$OUT" | wc -l | tr -d ' '); check capture-no-files "$( [[ $n == 0 ]] && echo ok)"

# Keep Awake
"$CLI" keep-awake seconds=3 --out "$OUT" > $TMP/ka.txt 2>&1 &
sleep 1
a=$(pmset -g assertions | grep 'Toolbox Keep Awake'); check keep-awake-assertion "$(has "$a" PreventUserIdleSystemSleep)"
wait
check keep-awake-text "$(has "$(cat $TMP/ka.txt)" "Kept awake for 3 s.")"
check keep-awake-released "$( [[ $(assertions) == 0 ]] && echo ok)"
"$CLI" keep-awake seconds=3 display=true --out "$OUT" > /dev/null 2>&1 &
sleep 1
a=$(pmset -g assertions | grep 'Toolbox Keep Awake'); check keep-awake-display "$(has "$a" PreventUserIdleDisplaySleep)"
wait
"$CLI" keep-awake duration=forever --out "$OUT" > $TMP/ka2.txt 2>&1 &
p=$!; sleep 1.5; kill -INT $p; wait $p
check keep-awake-cancel "$( [[ $(assertions) == 0 ]] && grep -q 'then stopped' $TMP/ka2.txt && grep -q 'Cancelled' $TMP/ka2.txt && echo ok)"

# Network Speed Test
t=$(textout speed-test)
check speed-test "$(grep -qE '^Download +[0-9.,]+ Mbps' <<< "$t" && grep -qE '^Upload +[0-9.,]+ Mbps' <<< "$t" && grep -qE '^Responsiveness +(Low|Medium|High), [0-9,]+ RPM' <<< "$t" && grep -qE '^Idle latency +[0-9,]+ ms' <<< "$t" && grep -q '^Interface' <<< "$t" && echo ok)" "$(head -1 <<< "$t")"
"$CLI" speed-test --out "$OUT" > /dev/null 2>&1 &
p=$!; sleep 3; kill -INT $p; wait $p; sleep 0.5
check speed-test-cancel "$( ! pgrep -x networkQuality > /dev/null && echo ok)"

# Fix "App Is Damaged"
APP=""
for c in /Applications/Maccy.app /Applications/Boop.app /Applications/Rectangle.app; do [[ -d $c ]] && { APP=$c; break; }; done
if [[ -n $APP ]]; then
    ditto "$APP" $TMP/Test.app
    xattr -w com.apple.quarantine "0081;00000000;Safari;" $TMP/Test.app
    t=$(textout fix-app mode=check $TMP/Test.app)
    check fix-app-check "$( grep -q '^Test is quarantined' <<< "$t" && grep -q 'downloaded with Safari' <<< "$t" && grep -q 'Notarized Developer ID' <<< "$t" && xattr -p com.apple.quarantine $TMP/Test.app > /dev/null 2>&1 && echo ok)"
    t=$(textout fix-app $TMP/Test.app)
    check fix-app-fix "$( grep -q '^Fixed: quarantine removed. You can open Test now.' <<< "$t" && ! xattr -p com.apple.quarantine $TMP/Test.app > /dev/null 2>&1 && echo ok)"
    check fix-app-signed "$( grep -q '^Signed by: Developer ID Application' <<< "$t" && ! grep -q 'Only open it' <<< "$t" && echo ok)"
    t=$(textout fix-app $TMP/Test.app); check fix-app-nothing "$(has "$t" "Nothing to fix: Test isn't quarantined.")"
else
    skip fix-app "(no small notarized app in /Applications to copy)"
fi
mkdir -p $TMP/Fake.app/Contents/MacOS
print '<?xml version="1.0" encoding="UTF-8"?>\n<plist version="1.0"><dict><key>CFBundleExecutable</key><string>Fake</string><key>CFBundleIdentifier</key><string>com.example.fake</string><key>CFBundlePackageType</key><string>APPL</string></dict></plist>' > $TMP/Fake.app/Contents/Info.plist
print '#!/bin/sh\necho hi' > $TMP/Fake.app/Contents/MacOS/Fake; chmod +x $TMP/Fake.app/Contents/MacOS/Fake
xattr -w com.apple.quarantine "0083;6717abcd;Chrome;" $TMP/Fake.app
t=$(textout fix-app $TMP/Fake.app)
check fix-app-unsigned "$( grep -q '^Fixed' <<< "$t" && grep -q "This app isn't signed" <<< "$t" && grep -q 'Signed by: not signed' <<< "$t" && grep -q 'no usable signature' <<< "$t" && grep -q 'downloaded with Chrome' <<< "$t" && echo ok)"
check fix-app-untouched "$( [[ "$(cat $TMP/Fake.app/Contents/MacOS/Fake)" == $'#!/bin/sh\necho hi' ]] && ! codesign -v $TMP/Fake.app 2>/dev/null && echo ok)"
t=$(textout fix-app mode=check /System/Applications/Calculator.app); check fix-app-system "$( grep -q 'Nothing to fix' <<< "$t" && grep -q 'Apple System' <<< "$t" && echo ok)"
e=$(failout fix-app $F/photo.png); check fix-app-not-app "$( [[ -n $e ]] && echo ok)" "$e"

echo "$pass passed, $fail failed"
[[ $fail == 0 ]]
