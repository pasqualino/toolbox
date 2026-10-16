#!/bin/zsh
# Exact-output checks for the Developer encoding tools. Usage: CLI=path/to/toolbox-cli Fixtures/dev/check-enc.sh
set -u
export LC_ALL=en_US.UTF-8
CLI=${CLI:-/Users/marcos/workspace/toolbox/.build/release/toolbox-cli}
pass=0; fail=0

# eq NAME EXPECTED TOOL [args...]: runs the tool and compares its whole output.
eq() {
  local name=$1 want=$2; shift 2
  local got; got=$("$CLI" "$@" 2>&1)
  if [[ "$got" == "$want" ]]; then echo "PASS $name"; pass=$((pass+1))
  else echo "FAIL $name"; print -r -- "  want: ${(q+)want}"; print -r -- "  got:  ${(q+)got}"; fail=$((fail+1)); fi
}
# trip NAME ENCODER DECODER TEXT [encoder args...]: decode(encode(text)) == text.
trip() {
  local name=$1 enc=$2 dec=$3 text=$4; shift 4
  local mid; mid=$("$CLI" $enc "$@" --text "$text" 2>&1)
  eq "$name" "$text" $dec --text "$mid"
}

U=$'Grüße, "world" & <tags>\n\ttab \\ 😀'

# Base64
eq b64-encode 'aGk/Pg==' base64-encode --text 'hi?>'
eq b64-encode-urlsafe 'aGk_Pg' base64-encode urlsafe=true --text 'hi?>'
eq b64-decode-url-nopad 'hi?>' base64-decode --text 'aGk_Pg'
eq b64-decode-whitespace 'hello world' base64-decode --text $'aGVs\nbG8 gd29y bGQ'
eq b64-decode-dataurl 'hi' base64-decode --text 'data:text/plain;base64,aGk='
eq b64-decode-binary $'Decoded 8 bytes of binary data (not UTF-8 text).\nFirst bytes: 89 50 4e 47 0d 0a 1a 0a' base64-decode --text 'iVBORw0KGgo='
eq b64-decode-invalid 'error: That isn'"'"'t valid Base64: unexpected "%".' base64-decode --text 'a%b'
eq b64-decode-empty '' base64-decode --text '   '
trip b64-trip base64-encode base64-decode "$U"
trip b64-trip-urlsafe base64-encode base64-decode "$U" urlsafe=true

# URL
eq url-encode-component 'a%20b%26c%3Dd%2F%C3%A9' url-encode --text 'a b&c=d/é'
eq url-encode-whole 'https://x.com/a%20b?q=1&r=%C3%A9#f' url-encode mode=url --text 'https://x.com/a b?q=1&r=é#f'
eq url-decode 'a b c%zzé' url-decode --text 'a+b%20c%zz%C3%A9'
eq url-decode-plus-off 'a+b' url-decode plus=false --text 'a+b'
eq url-decode-bad-utf8 'error: The decoded bytes aren'"'"'t valid UTF-8 text.' url-decode --text '%ff'
trip url-trip url-encode url-decode "$U"

# HTML
eq html-encode '&lt;a href=&#39;x&#39;&gt;é &amp; &quot;&lt;/a&gt;' html-encode --text "<a href='x'>é & \"</a>"
eq html-encode-nonascii 'caf&#233; &#128512;' html-encode nonascii=true --text 'café 😀'
eq html-decode $'<p>\u00a0\u00a9\u2014AB&bogus; & x' html-decode --text '&lt;p&gt;&nbsp;&copy;&mdash;&#65;&#x42;&bogus; & x'
trip html-trip html-encode html-decode "$U"
trip html-trip-nonascii html-encode html-decode "$U" nonascii=true

# String escaping
eq escape-string 'he said \"hi\"\n\ttab\\ \u0001 é' escape-string --text $'he said "hi"\n\ttab\\ \x01 é'
eq escape-string-ascii-quotes '"\u00e9\ud83d\ude00"' escape-string ascii=true quotes=true --text 'é😀'
eq unescape-quoted '{"a":"b'$'\n''c","e":"é😀"}' unescape-string --text '"{\"a\":\"b\nc\",\"e\":\"\u00e9\ud83d\ude00\"}"'
eq unescape-bare 'say "hi"' unescape-string --text 'say \"hi\"'
eq unescape-bad-u 'error: Bad \u escape: it needs four hex digits.' unescape-string --text '\u12'
trip escape-trip escape-string unescape-string "$U"
trip escape-trip-spaces escape-string unescape-string '  padded  '
trip escape-trip-ascii escape-string unescape-string "$U" ascii=true quotes=true

# Hex
eq ascii-to-hex '48 69 20 c3 a9' ascii-to-hex --text 'Hi é'
eq hex-to-ascii 'Hi é' hex-to-ascii --text '0x48 0x69:20,c3 a9'
eq hex-to-ascii-escapes 'Hi' hex-to-ascii --text '\x48\x69'
eq hex-to-ascii-odd 'error: Odd number of hex digits; each byte needs two.' hex-to-ascii --text '486'
eq hex-to-ascii-binary $'Decoded 2 bytes of binary data (not UTF-8 text).\nFirst bytes: ff fe' hex-to-ascii --text 'ff fe'
trip hex-trip ascii-to-hex hex-to-ascii "$U"

# Hash
eq hash-sha256 'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad' hash --text abc
eq hash-md5 '900150983cd24fb0d6963f7d28e17f72' hash algo=md5 --text abc
eq hash-sha1-base64 'qZk+NkcGgWq6PiVxeFDCbJzQ2J0=' hash algo=sha1 format=base64 --text abc
eq hash-sha512 'ddaf35a193617abacc417349ae20413112e6fa4e89a97ea20a9eeee64b55d39a2192992a274fc1a836ba3c23a3feebbd454d4423643ce80e2a9ac94fa54ca49f' hash algo=sha512 --text abc

# HMAC (RFC test vector "The quick brown fox" with key "key")
Q='The quick brown fox jumps over the lazy dog'
S256=f7bc83f430538424b13298e6aa6fb143ef4d59a14946175997479dbc2d1a3cd8
eq hmac-sha256 $S256 hmac key=key --text "$Q"
eq hmac-sha1 'de7c9b85b8b78aa6bc8a7a36f70a90701c9db4d9' hmac key=key algo=sha1 --text "$Q"
eq hmac-base64 '97yD9DBThCSxMpjmqm+xQ+9NWaFJRhdZl0edvC0aPNg=' hmac key=key format=base64 --text "$Q"
eq hmac-match-github "$S256"$'\n\nMatches expected signature' hmac key=key expected=sha256=${S256:u} --text "$Q"
eq hmac-match-base64 "$S256"$'\n\nMatches expected signature' hmac key=key expected=97yD9DBThCSxMpjmqm+xQ+9NWaFJRhdZl0edvC0aPNg= --text "$Q"
eq hmac-mismatch "$S256"$'\n\nDoes NOT match expected signature' hmac key=key expected=${S256/f7/00} --text "$Q"
eq hmac-no-key 'error: Enter the secret key.' hmac --text x

# Number base
eq number-base $'Decimal  255\nHex      0xff\nBinary   1111 1111\nOctal    0o377' number-base --text 255
eq number-base-multi $'Input    0b1010\nDecimal  10\nHex      0xa\nBinary   1010\nOctal    0o12\n\nInput    deadbeef\nDecimal  3735928559\nHex      0xdeadbeef\nBinary   1101 1110 1010 1101 1011 1110 1110 1111\nOctal    0o33653337357' number-base --text $'0b1010\ndeadbeef'
eq number-base-signed $'Decimal  18446744073709551615\nHex      0xffffffffffffffff\nBinary   1111 1111 1111 1111 1111 1111 1111 1111 1111 1111 1111 1111 1111 1111 1111 1111\nOctal    0o1777777777777777777777\nSigned   -1' number-base --text -1
eq number-base-overflow 'error: 18446744073709551616 is larger than 64 bits.' number-base --text 18446744073709551616
eq number-base-invalid 'error: Couldn'"'"'t read "xyz" as a number.' number-base --text xyz

# Color
eq color-hex3 $'Hex      #ff8800\nRGB      rgb(255, 136, 0)\nHSL      hsl(32, 100%, 50%)\nSwiftUI  Color(red: 1, green: 0.533, blue: 0)\nUIColor  UIColor(red: 1, green: 0.533, blue: 0, alpha: 1)\nNSColor  NSColor(srgbRed: 1, green: 0.533, blue: 0, alpha: 1)' color-convert --text '#f80'
eq color-rgba $'Hex      #ff880080\nRGB      rgba(255, 136, 0, 0.5)\nHSL      hsla(32, 100%, 50%, 0.5)\nSwiftUI  Color(red: 1, green: 0.533, blue: 0, opacity: 0.5)\nUIColor  UIColor(red: 1, green: 0.533, blue: 0, alpha: 0.5)\nNSColor  NSColor(srgbRed: 1, green: 0.533, blue: 0, alpha: 0.5)' color-convert --text 'rgba(255, 136, 0, 0.5)'
eq color-hsl $'Hex      #336699\nRGB      rgb(51, 102, 153)\nHSL      hsl(210, 50%, 40%)\nSwiftUI  Color(red: 0.2, green: 0.4, blue: 0.6)\nUIColor  UIColor(red: 0.2, green: 0.4, blue: 0.6, alpha: 1)\nNSColor  NSColor(srgbRed: 0.2, green: 0.4, blue: 0.6, alpha: 1)' color-convert --text 'hsl(210deg 50% 40%)'
eq color-invalid 'error: Use #rgb, #rrggbb, #rrggbbaa, rgb(), rgba() or hsl().' color-convert --text nope

# ROT13, defang
eq rot13 'Uryyb, Jbeyq!' rot13 --text 'Hello, World!'
trip rot13-trip rot13 rot13 "$U"
eq defang 'Visit hxxps://evil[.]example[.]com/a.php?x=1 or mail bob[at]evil[.]com, ip 10[.]0[.]0[.]1. Done.' defang-url --text 'Visit https://evil.example.com/a.php?x=1 or mail bob@evil.com, ip 10.0.0.1. Done.'
eq refang 'https://evil.example.com/a.php bob@evil.com 10.0.0.1 http://x.io ftp://y.z' refang-url --text 'hxxps[://]evil[.]example(.)com/a.php bob[at]evil[dot]com 10[.]0[.]0[.]1 hXXp://x[.]io fxp://y[.]z'
trip defang-trip defang-url refang-url 'Visit https://evil.example.com/a.php?x=1 or mail bob@evil.com, ip 10.0.0.1. Done.'

echo "$pass passed, $fail failed"
(( fail == 0 ))
