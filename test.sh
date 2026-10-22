#!/bin/zsh
# Builds the release CLI and runs every Fixtures check script against it. Exits non-zero if any check fails.
# Usage: ./test.sh               every script
#        ./test.sh dev media     only scripts whose path contains one of the words
# check-mac, check-net and check-other need a network connection.
set -u
cd "${0:A:h}"

swift build -c release --product toolbox-cli || exit 1
export CLI=$PWD/.build/release/toolbox-cli

scripts=(Fixtures/**/check-*.sh(N))
if (( $# )); then
    scripts=(${(M)scripts:#*(${(j:|:)~@})*})
fi
(( ${#scripts} )) || { echo "No check scripts match: $*"; exit 1; }

total_pass=0
total_fail=0
failed=()
for script in $scripts; do
    output=$(zsh $script </dev/null 2>&1)
    code=$?
    summary=$(print -r -- "$output" | grep -E '^[0-9]+ passed, [0-9]+ failed' | tail -1)
    if [[ $summary =~ '^([0-9]+) passed, ([0-9]+) failed' ]]; then
        pass=$match[1]
        fail=$match[2]
    else
        # No summary line: the script stopped early.
        pass=0
        fail=1
    fi
    (( total_pass += pass, total_fail += fail ))
    printf "%-34s %4d passed, %d failed\n" $script $pass $fail
    if (( fail > 0 || code != 0 )); then
        failed+=$script
        # Each FAIL line, with its indented want/got lines.
        print -r -- "$output" | awk '/^FAIL /{show=1; print "    " $0; next} show && /^  /{print "    " $0; next} {show=0}'
        [[ -z $summary ]] && print -r -- "$output" | tail -5 | sed 's/^/    /'
    fi
done

echo "Total: $total_pass passed, $total_fail failed"
(( ${#failed} == 0 ))
