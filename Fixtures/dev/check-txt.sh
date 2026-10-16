#!/bin/zsh
# Checks for the developer text and workflow tools. Usage: CLI=path/to/toolbox-cli Fixtures/dev/check-txt.sh
set -u
export TZ=Europe/Berlin LC_ALL=en_US.UTF-8
CLI=${CLI:-/Users/marcos/workspace/toolbox/.build/release/toolbox-cli}
pass=0; fail=0

r() { "$CLI" "$@" 2>&1 </dev/null; }
ok() { echo "PASS $1"; pass=$((pass+1)); }
no() { echo "FAIL $1${2:+  $2}"; fail=$((fail+1)); }
eq() { if [[ "$3" == "$2" ]]; then ok "$1"; else no "$1"; print -r -- "  expected: ${(q)2}"; print -r -- "  actual:   ${(q)3}"; fi; }
has() { if print -r -- "$3" | grep -qF -- "$2"; then ok "$1"; else no "$1" "missing: $2"; print -r -- "$3" | sed 's/^/    /'; fi; }
like() { if [[ "$3" =~ $2 ]]; then ok "$1"; else no "$1" "no match for $2: $3"; fi; }

# Case
W=$'HTTPServerError\nuser_id\nsome-thing fooBar2Baz\nhello, world!'
eq camel-case    $'httpServerError\nuserId\nsomeThingFooBar2Baz\nhelloWorld'          "$(r camel-case --text $W)"
eq pascal-case   $'HttpServerError\nUserId\nSomeThingFooBar2Baz\nHelloWorld'          "$(r pascal-case --text $W)"
eq snake-case    $'http_server_error\nuser_id\nsome_thing_foo_bar2_baz\nhello_world'  "$(r snake-case --text $W)"
eq kebab-case    $'http-server-error\nuser-id\nsome-thing-foo-bar2-baz\nhello-world'  "$(r kebab-case --text $W)"
eq constant-case $'HTTP_SERVER_ERROR\nUSER_ID\nSOME_THING_FOO_BAR2_BAZ\nHELLO_WORLD'  "$(r constant-case --text $W)"
eq title-case    $'Http Server Error\nUser Id\nSome Thing Foo Bar2 Baz\nHello World'  "$(r title-case --text $W)"
eq upper-case    'CAFÉ USER_ID' "$(r upper-case --text 'café user_id')"
eq lower-case    'café user_id' "$(r lower-case --text 'CAFÉ User_ID')"
eq sponge-case   'hElLo, WoRlD' "$(r sponge-case --text 'hello, world')"
eq case-roundtrip 'fooBarBazQux' "$(r camel-case --text "$(r snake-case --text 'fooBarBazQux')")"

# Lines
eq sort-natural   $'b\nfile1\nFile2\nfile10' "$(r sort-lines --text $'file10\nFile2\nfile1\nb')"
eq sort-desc      $'file10\nfile2\nfile1'    "$(r sort-lines order=desc --text $'file1\nfile10\nfile2')"
eq sort-plain     $'file1\nfile10\nfile2'    "$(r sort-lines natural=false --text $'file2\nfile10\nfile1')"
eq sort-case      $'B\na\nb'                 "$(r sort-lines ignorecase=false natural=false --text $'b\na\nB')"
eq reverse-lines  $'c\nb\na'                 "$(r reverse-lines --text $'a\nb\nc')"
s=$(r shuffle-lines --text $'1\n2\n3\n4\n5\n6\n7\n8\n9\n10')
eq shuffle-same-set "$(seq 1 10)" "$(print -r -- $s | sort -n)"
eq dedupe-lines   $'a\nA\nb'                 "$(r dedupe-lines --text $'a\nA\nb\na')"
eq dedupe-nocase  $'a\nb'                    "$(r dedupe-lines ignorecase=true --text $'a\nA\nb\na')"
eq trim-lines     $'a\n\nb'                  "$(r trim-lines --text $'  a  \n\n\tb ')"
eq trim-dropempty $'a\nb'                    "$(r trim-lines dropempty=true --text $'  a  \n\n\tb ')"
eq collapse-space 'a b c'                    "$(r collapse-lines --text $'a\n b \n\nc')"
eq collapse-comma 'a, b, c'                  "$(r collapse-lines sep=comma --text $'a\n b \n\nc')"
eq collapse-none  'abc'                      "$(r collapse-lines sep=none --text $'a\nb\nc')"
eq number-lines   $'1  a\n2  b'              "$(r number-lines --text $'a\nb')"
eq markdown-quote $'> hi\n>\n> there'        "$(r markdown-quote --text $'hi\n\nthere')"
eq reverse-text   '👍🏽 olléh'                "$(r reverse-text --text 'héllo 👍🏽')"

# Reports
eq count-text $'Characters      34\nWithout spaces  27\nWords           6\nLines           3\nParagraphs      2\nBytes (UTF-8)   42\nReading time    under 1 min at 238 wpm' \
  "$(r count-text --text $'Hello world, café.\n\nSecond para 👍🏽\n')"
eq count-empty '' "$(r count-text --text '')"
eq sum-all $'Sum      1236.06\nCount    5\nAverage  247.212\nMin      -5472\nMax      5472' \
  "$(r sum-all --text 'Total 1,234.56 minus -10, ticket ABC-5472 v2 sha256 (-5472) plus 11.5')"
eq sum-none 'error: No numbers found.' "$(r sum-all --text 'no digits here')"
eq sum-list $'Sum      6\nCount    3\nAverage  2\nMin      1\nMax      3' "$(r sum-all --text '1,2,3')"

# Generators and cleanup
l1=$(r lorem-ipsum); l2=$(r lorem-ipsum)
eq lorem-paragraphs 3 "$(print -r -- $l1 | grep -c .)"
like lorem-start '^Lorem ipsum dolor sit amet' "$l1"
[[ $l1 != $l2 ]] && ok lorem-differs || no lorem-differs
eq lorem-words 'Lorem ipsum dolor sit amet' "$(r lorem-ipsum unit=words count=5)"
eq lorem-words-count 12 "$(r lorem-ipsum unit=words count=12 | wc -w | tr -d ' ')"
eq lorem-sentences 4 "$(r lorem-ipsum unit=sentences count=4 | grep -o '\.' | wc -l | tr -d ' ')"
eq straight-quotes $'"Hi" it\'s -- fine - ok...' "$(r straight-quotes --text $'\u201cHi\u201d it\u2019s \u2014 fine \u2013 ok\u2026')"
eq remove-diacritics 'Creme brulee, Lodz, strasse, Orsted' "$(r remove-diacritics --text 'Crème brûlée, Łódź, straße, Ørsted')"

# JWT
b64() { print -rn -- "$1" | base64 | tr '+/' '-_' | tr -d '=\n'; }
H=$(b64 '{"alg":"RS256","typ":"JWT","kid":"abc"}')
P=$(b64 '{"iss":"https://example.eu.auth0.com/","sub":"auth0|123","aud":["https://api.example.com","https://example.eu.auth0.com/userinfo"],"azp":"xyz","scope":"openid profile","permissions":["read:content"],"iat":1761055380,"exp":1761062580,"https://example.com/roles":["admin"]}')
j=$(r decode-jwt --text "  \"Bearer $H.$P.sig\" ")
has jwt-header   $'Header\n{\n  "alg": "RS256",\n  "kid": "abc",\n  "typ": "JWT"\n}' "$j"
has jwt-issuer   'Issuer                     https://example.eu.auth0.com/' "$j"
has jwt-aud      'Audience                   https://api.example.com, https://example.eu.auth0.com/userinfo' "$j"
has jwt-perms    'Permissions                read:content' "$j"
has jwt-iat      $'Issued at                  Tue 2025-10-21 16:03:00 GMT+2\n                           2025-10-21T14:03:00Z' "$j"
has jwt-expired  'Status                     Expired ' "$j"
has jwt-lifetime 'Lifetime                   2 h' "$j"
has jwt-custom   'https://example.com/roles  admin' "$j"
has jwt-sig      'Signature not verified (alg RS256).' "$j"
exp=$(( $(date +%s) + 7400 ))
P2=$(b64 "{\"sub\":\"x\",\"exp\":$exp}")
has jwt-valid 'Valid, expires in 2 h 3 min' "$(r decode-jwt --text "$H.$P2.")"
eq jwt-bad 'error: A JWT has three parts separated by dots.' "$(r decode-jwt --text 'abc')"
eq jwt-jwe 'error: This is an encrypted JWE; only signed JWTs can be decoded.' "$(r decode-jwt --text 'a.b.c.d.e')"

# Epoch
e=$(r epoch-converter --text 1761055380000)
has epoch-ms $'Input     1761055380000 (milliseconds)\nUTC       2025-10-21T14:03:00Z\nLocal     Tue 2025-10-21 16:03:00 GMT+2 (Europe/Berlin)' "$e"
has epoch-ms-back $'Epoch s   1761055380\nEpoch ms  1761055380000' "$e"
has epoch-s  'Input     1761055380 (seconds)' "$(r epoch-converter --text 1761055380)"
has epoch-us 'UTC       2025-10-21T14:03:00.123Z' "$(r epoch-converter --text 1761055380123456)"
has epoch-ns 'Input     1761055380123456789 (nanoseconds)' "$(r epoch-converter --text 1761055380123456789)"
has epoch-naive $'Input     2026-10-21 14:03:00 (no zone, read as UTC)\nUTC       2026-10-21T14:03:00Z' "$(r epoch-converter --text '2026-10-21 14:03:00')"
has epoch-local 'UTC       2026-10-21T12:03:00Z' "$(r epoch-converter zone=local --text '2026-10-21 14:03:00')"
has epoch-iso   'UTC       2026-10-21T12:03:00.500Z' "$(r epoch-converter --text '2026-10-21T14:03:00.5+02:00')"
has epoch-rfc   'Epoch s   1761055380' "$(r epoch-converter --text 'Tue, 21 Oct 2025 14:03:00 +0000')"
has epoch-clf   'Epoch s   1761055380' "$(r epoch-converter --text '[21/Oct/2025:14:03:00 +0000]')"
has epoch-date  'Epoch s   1792591380' "$(r epoch-converter --text 'Wed Oct 21 14:03:00 UTC 2026')"
has epoch-multi 'Input     1761055380 (seconds)' "$(r epoch-converter --text $'1761055380000\n1761055380')"
has epoch-now   'Input     now' "$(r epoch-converter)"
has epoch-now-s "Epoch s   $(date +%s | cut -c1-8)" "$(r epoch-converter)"
eq epoch-bad 'error: Not an epoch or a date I can read. Try 1761055380, 2026-10-21T14:03:00Z or an RFC 2822 date.' "$(r epoch-converter --text 'nope')"

# Cron
has cron-daily  'Schedule  At 12:00 UTC every day' "$(r explain-cron --text '0 12 * * *')"
has cron-aws    'Schedule  At 12:00 UTC every day' "$(r explain-cron --text 'cron(0 12 * * ? *)')"
has cron-weekdays 'Schedule  Every 15 minutes, between 09:00 and 17:59 UTC, on Monday through Friday' "$(r explain-cron --text '*/15 9-17 * * MON-FRI')"
has cron-times  'Schedule  At 09:00 and 17:00 UTC on Monday through Friday' "$(r explain-cron --text '0 9,17 * * 1-5')"
has cron-hourly 'Schedule  Every hour at minute 0, every day (UTC)' "$(r explain-cron --text '@hourly')"
has cron-step   'Schedule  Every 2 hours at minute 0 UTC, every day' "$(r explain-cron --text '0 */2 * * *')"
has cron-seconds 'Schedule  Every 10 seconds, every day (UTC)' "$(r explain-cron --text '*/10 * * * * *')"
has cron-last   'Schedule  At 00:00 UTC on the last day of the month' "$(r explain-cron --text '0 0 L * ?')"
has cron-nth    'Schedule  At 00:00 UTC on the third Friday of the month' "$(r explain-cron --text 'cron(0 0 ? * 6#3 *)')"
has cron-or     'on days 1 and 15 of the month or on Monday' "$(r explain-cron --text '0 0 1,15 * 1')"
has cron-feb29  $'Schedule  At 00:00 UTC on February 29\nFields    minute 0, hour 0, day 29, month 2, weekday *\n\nNext 5 runs (UTC)\n  Tue 2028-02-29 00:00 UTC   Tue 2028-02-29 01:00 GMT+1' "$(r explain-cron --text '0 0 29 2 *')"
has cron-local  'Next 5 runs (Europe/Berlin)' "$(r explain-cron zone=local --text '0 9 * * 1-5')"
has cron-command 'Fields    minute */5, hour *, day *, month *, weekday *' "$(r explain-cron --text '*/5 * * * * /usr/bin/backup.sh')"
has cron-rate   'Schedule  Every 5 minutes' "$(r explain-cron --text 'rate(5 minutes)')"
eq cron-range 'error: 60 is out of range 0-59.' "$(r explain-cron --text '60 * * * *')"
eq cron-fields 'error: Cron needs 5 fields (minute hour day month weekday), or 6 with seconds first.' "$(r explain-cron --text 'a b c')"
eq cron-runs 5 "$(r explain-cron --text '0 0 1 1 *' | grep -c '^  ')"

# URL
u=$(r parse-url --text 'https://user:pw@auth.example.com:8443/authorize/v2?response_type=code&redirect_uri=https%3A%2F%2Fapp.example.com%2Fcb%3Fx%3D1&scope=openid+profile%20email&scope=extra#access_token=tok&expires_in=7200')
has url-head $'Scheme    https\nUser      user\nPassword  pw\nHost      auth.example.com\nPort      8443\nPath      /authorize/v2' "$u"
has url-segments $'Segments\n  1  authorize\n  2  v2' "$u"
has url-query $'Query (4 params)\n  response_type  code\n  redirect_uri   https://app.example.com/cb?x=1\n  scope          openid profile email\n  scope          extra' "$u"
has url-nested $'redirect_uri query\n  x  1' "$u"
has url-fragment $'Fragment params\n  access_token  tok\n  expires_in    7200' "$u"
has url-assumed $'Scheme  https (assumed)\nHost    example.com\nPort    443 (default)' "$(r parse-url --text 'example.com/a')"
eq url-bad 'error: That isn'"'"'t a URL. Paste something like https://example.com/path?x=1.' "$(r parse-url --text 'not a url')"

# Branch
eq branch-text  'marcos/abc-5472-retry-failed-webhook-calls' "$(r branch-name --text 'ABC-5472 Retry failed webhook calls')"
eq branch-linear 'marcos/abc-5181-fix-csv-export-bug-after-sheets-sync' "$(r branch-name --text 'https://linear.app/acme/issue/ABC-5181/fix-csv-export-bug-after-sheets-sync')"
eq branch-same "$(r branch-name --text 'ABC-5181 Fix CSV export bug after Sheets sync')" "$(r branch-name --text 'https://linear.app/acme/issue/ABC-5181/fix-csv-export-bug-after-sheets-sync')"
eq branch-max   'marcos/ABC-5181-fix-csv-export' "$(r branch-name lowerticket=false max=30 --text 'ABC-5181: Fix CSV export bug!!')"
eq branch-noticket 'fix-the-thing' "$(r branch-name prefix= --text 'Fix the thing')"

# IDs
like gen-uuid4 '^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$' "$(r generate-id)"
like gen-uuid4-upper '^[0-9A-F]{8}-[0-9A-F]{4}-4' "$(r generate-id upper=true)"
like gen-uuid7 '^[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$' "$(r generate-id type=uuid7)"
like gen-ulid '^[0-7][0-9A-HJKMNP-TV-Z]{25}$' "$(r generate-id type=ulid)"
like gen-cuid '^c[0-9a-z]{24}$' "$(r generate-id type=cuid)"
like gen-cuid2 '^[a-z][0-9a-z]{23}$' "$(r generate-id type=cuid2)"
like gen-nanoid '^[A-Za-z0-9_-]{21}$' "$(r generate-id type=nanoid)"
eq gen-count 1000 "$(r generate-id count=1000 type=cuid | sort -u | wc -l | tr -d ' ')"
[[ $(r generate-id type=nanoid) != $(r generate-id type=nanoid) ]] && ok gen-differs || no gen-differs
year=$(date -u +%Y)
for t in uuid7 ulid cuid; do
  like inspect-$t "Timestamp +$year-" "$(r inspect-id --text "$(r generate-id type=$t)")"
done
has inspect-uuid4 'Type       UUID v4 (random)' "$(r inspect-id --text "$(r generate-id)")"
has inspect-cuid2 'cuid2 (probably)' "$(r inspect-id --text "$(r generate-id type=cuid2)")"
has inspect-v1 $'Type            UUID v1 (time-based)\nVariant         RFC 9562\nCanonical       c232ab00-9414-11ec-b3c8-9f6bdeced846\nTimestamp       2022-02-22T19:22:22Z' "$(r inspect-id --text '{C232AB00-9414-11EC-B3C8-9F6BDECED846}')"
has inspect-v6 'Timestamp       2022-02-22T19:22:22Z' "$(r inspect-id --text '1ec9414c-232a-6b00-b3c8-9f6bdeced846')"
has inspect-v7 'Timestamp  2022-02-22T19:22:22Z' "$(r inspect-id --text '017f22e2-79b0-7cc3-98c4-dc0c0c07398f')"
has inspect-objectid $'Type       MongoDB ObjectId\nTimestamp  2023-11-14T22:13:20Z' "$(r inspect-id --text '6553f100a1b2c3d4e5f60718')"
has inspect-ksuid $'Type       KSUID\nTimestamp  2017-10-10T04:00:47Z' "$(r inspect-id --text '0ujtsYcgvSTl8PAuAdqWYSMnLOv')"
has inspect-ulid 'Timestamp  2016-07-30T23:54:10.259Z' "$(r inspect-id --text '01ARZ3NDEKTSV4RRFFQ69G5FAV')"
has inspect-cuid 'Timestamp    2017-05-21T11:08:34.184Z' "$(r inspect-id --text 'cj2ylnsaw0000kfvx44uqnlot')"
eq inspect-bad 'error: Not a recognized ID. Try a UUID, ULID, cuid, ObjectId or KSUID.' "$(r inspect-id --text 'hello')"

# Diff
eq diff-change $'@@ -1,5 +1,5 @@\n  a\n- b\n+ B\n  c\n  d\n  e\n@@ -11,3 +11,4 @@\n  k\n  l\n  m\n+ n' \
  "$(r text-diff --text $'a\nb\nc\nd\ne\nf\ng\nh\ni\nj\nk\nl\nm' --text2 $'a\nB\nc\nd\ne\nf\ng\nh\ni\nj\nk\nl\nm\nn')"
eq diff-same 'No differences.' "$(r text-diff --text $'a\nb' --text2 $'a\nb\n')"
eq diff-ws 'No differences.' "$(r text-diff ignorews=true --text $'a\n  b' --text2 $'a\nb  ')"
eq diff-ws-off $'@@ -1,2 +1,2 @@\n  a\n-   b\n+ b  ' "$(r text-diff --text $'a\n  b' --text2 $'a\nb  ')"
eq diff-added $'@@ -0,0 +1,2 @@\n+ x\n+ y' "$(r text-diff --text '' --text2 $'x\ny')"
eq diff-empty '' "$(r text-diff)"

# Registry
ids=(camel-case pascal-case snake-case kebab-case constant-case title-case upper-case lower-case sponge-case sort-lines
     reverse-lines shuffle-lines dedupe-lines trim-lines collapse-lines number-lines markdown-quote reverse-text count-text
     sum-all lorem-ipsum straight-quotes remove-diacritics decode-jwt epoch-converter explain-cron parse-url branch-name
     generate-id inspect-id text-diff)
listed=$("$CLI" list | grep -v '^ ')
missing=0; for id in $ids; do print -r -- "$listed" | grep -qx "$id" || { missing=$((missing+1)); echo "  not listed: $id"; }; done
eq registry 0 $missing

echo "$pass passed, $fail failed"
(( fail == 0 ))
