#!/bin/zsh
# Checks for Network Health. Usage: Fixtures/batch1/check-net.sh
# Needs a network connection for the live run (~5 s). The verdict checks feed fixed checks through simulate=.
set -u
ROOT=/Users/marcos/workspace/toolbox
CLI=${CLI:-$ROOT/.build/release/toolbox-cli}
OUT=$(mktemp -d)
TMP=$(mktemp -d)
trap 'rm -rf "$OUT" "$TMP"' EXIT
pass=0; fail=0

check() { if [[ "$2" == ok ]]; then echo "PASS $1 ${3:-}"; pass=$((pass+1)); else echo "FAIL $1 ${3:-}"; fail=$((fail+1)); fi; }
# Text-only tools print their result as "text: ..." and save nothing.
textout() { "$CLI" "$@" --out "$OUT" 2>&1 | awk '/^text: /{on=1; sub(/^text: /,"")} /^(ok   |FAIL |-> )/{on=0} on'; }
has() { grep -qF -- "$2" <<< "$1" && echo ok || echo no; }
pings() { pgrep -f 'ping -c 10 -i 0.2' > /dev/null; }

# Listing
l=$("$CLI" list); check list "$(has "$l" "network-health")"

# Live run
start=$(date +%s)
t=$(textout network-health)
secs=$(( $(date +%s) - start ))
check net-time "$( [[ $secs -lt 20 ]] && echo ok)" "(${secs} s)"
check net-verdict "$(grep -qE '^Verdict +[A-Z].+\.' <<< "$t" && echo ok)" "$(head -1 <<< "$t")"
check net-score "$(grep -qE '^Score +[0-9]{1,3}/100$' <<< "$t" && echo ok)" "$(grep '^Score' <<< "$t")"
groups=(Connection Router Internet DNS)
grep -qE '^  Interface +Wi-Fi' <<< "$t" && groups+=(Wi-Fi)
missing=(); for g in $groups; do grep -qx "$g" <<< "$t" || missing+=($g); done
check net-groups "$( [[ ${#missing} == 0 ]] && echo ok)" "${missing[*]:-}"
check net-latency "$(grep -qE '^  Latency +[0-9.]+ ms \((good|fair|poor)\)' <<< "$t" && echo ok)" "$(grep -m1 '^  Latency' <<< "$t")"
check net-dns "$(grep -qE '^  Lookups +([0-9.]+ ms|All)' <<< "$t" && grep -q '^  Servers' <<< "$t" && echo ok)"
check net-no-ssid "$( ! grep -qiE 'ssid|network name' <<< "$t" && echo ok)"
check net-no-files "$( [[ $(ls "$OUT" | wc -l | tr -d ' ') == 0 ]] && echo ok)"

# Cancel mid-run: pings stop with it
"$CLI" network-health --out "$OUT" > $TMP/cancel.txt 2>&1 &
p=$!; sleep 1
pings; running=$?
kill -INT $p; wait $p; sleep 0.5
check net-cancel "$( [[ $running == 0 ]] && ! pings && grep -q 'Cancelled' $TMP/cancel.txt && echo ok)"

# Verdict logic on simulated checks
c() { print -n "{\"id\":\"$1\",\"group\":\"$2\",\"title\":\"$1\",\"value\":\"x\",\"level\":\"$3\"}"; }
# Healthy Wi-Fi checks; each case overrides some ids with "id=level".
scenario() {
    local -A lv=(connection.interface good connection.ipv4 good wifi.signal good wifi.snr good wifi.band good
                 router.latency good router.jitter good router.loss good internet.latency good internet.jitter good
                 internet.loss good internet.captive good dns.lookup good dns.uncached good dns.servers info)
    local wired=0 kv
    for kv in "$@"; do
        if [[ $kv == wired ]]; then wired=1; else lv[${kv%%=*}]=${kv#*=}; fi
    done
    local parts=() id group
    for id in ${(k)lv}; do
        group=${${id%%.*}/connection/Connection}; group=${group/wifi/Wi-Fi}; group=${group/router/Router}
        group=${group/internet/Internet}; group=${group/dns/DNS}
        [[ $wired == 1 && $group == Wi-Fi ]] && continue
        parts+=("$(c $id $group ${lv[$id]})")
    done
    print -n "[${(j:,:)parts}]" > $TMP/sim.json
    textout network-health simulate=$TMP/sim.json
}
verdict() { scenario "$@" | sed -n 's/^Verdict  *//p'; }
score() { scenario "$@" | sed -n 's/^Score  *\([0-9]*\)\/100$/\1/p'; }

v=$(verdict); check sim-healthy "$( [[ $v == "Your connection is healthy." && $(score) == 100 ]] && echo ok)" "$v"
v=$(verdict wifi.band=warning); check sim-tip "$(has "$v" "One tip below")" "$v"
v=$(verdict wifi.signal=bad); check sim-weak-wifi "$(has "$v" "Wi-Fi is the weak link: the signal is weak.")" "$v"
v=$(verdict wifi.snr=warning); check sim-noisy-wifi "$(has "$v" "Wi-Fi is the weak link: there's a lot of interference.")" "$v"
v=$(verdict router.jitter=bad internet.jitter=bad); check sim-router-jitter "$(has "$v" "Wi-Fi is the weak link: the connection to your router is unsteady.")" "$v"
v=$(verdict wired router.loss=bad); check sim-wired-local "$(has "$v" "Your local network is the weak link")" "$v"
v=$(verdict internet.latency=bad internet.loss=bad); check sim-upstream "$(has "$v" "past your router (internet provider)")" "$v"
v=$(verdict dns.lookup=bad); check sim-dns "$( [[ $v == "DNS is slow; sites take long to start loading." ]] && echo ok)" "$v"
v=$(verdict internet.captive=warning internet.loss=bad); check sim-captive "$(has "$v" "A sign-in page is blocking the internet")" "$v"
v=$(verdict internet.reach=bad); check sim-offline-upstream "$( [[ $v == "You're offline: your router answers"* && $(score internet.reach=bad) -le 10 ]] && echo ok)" "$v"
v=$(verdict connection.ipv4=bad); check sim-offline-address "$( [[ $v == "You're offline:"* && $(score connection.ipv4=bad) == 0 ]] && echo ok)" "$v"
v=$(verdict connection.interface=bad); check sim-offline-unplugged "$(has "$v" "You're offline: this Mac isn't connected")" "$v"
s1=$(score wifi.signal=warning); s2=$(score wifi.signal=bad)
check sim-score-order "$( [[ $s1 -lt 100 && $s2 -lt $s1 ]] && echo ok)" "($s1, $s2)"
t=$(textout network-health 'simulate=[{"id":"dns.lookup","group":"DNS","title":"Lookups","value":"200 ms (poor)","level":"bad","advice":"Set DNS."}]')
check sim-inline-json "$( grep -q '^DNS$' <<< "$t" && grep -q 'Fix: Set DNS.' <<< "$t" && echo ok)"

echo "$pass passed, $fail failed"
[[ $fail == 0 ]]
