#!/bin/zsh
# Exact-output checks for the Developer format tools. Usage: CLI=path/to/toolbox-cli Fixtures/dev/check-fmt.sh
set -u
export LC_ALL=en_US.UTF-8
CLI=${CLI:-/Users/marcos/workspace/toolbox/.build/release/toolbox-cli}
pass=0; fail=0

# eq NAME EXPECTED TOOL [args...]: runs the tool and compares its whole output.
eq() {
  local name=$1 want=$2; shift 2
  local got; got=$("$CLI" "$@" 2>&1 </dev/null)
  same "$name" "$want" "$got"
}
same() {
  if [[ "$3" == "$2" ]]; then echo "PASS $1"; pass=$((pass+1))
  else echo "FAIL $1"; print -r -- "  want: ${(q+)2}"; print -r -- "  got:  ${(q+)3}"; fail=$((fail+1)); fi
}
ok() { if [[ "$2" == yes ]]; then echo "PASS $1"; pass=$((pass+1)); else echo "FAIL $1 ${3:-}"; fail=$((fail+1)); fi; }
out() { "$CLI" "$@" 2>&1 </dev/null; }
# mj TEXT TOOL [args...]: runs the tool on TEXT and minifies its JSON output.
mj() { local t=$1; shift; "$CLI" "$@" --text "$t" 2>&1 </dev/null | "$CLI" minify-json 2>&1; }

# MARK: JSON
J='{"user":{"name":"Ana","id":1.0},"exp":12345678901234567890,"big":1e5,"neg":-0.5E-3,"u":"caf\u00e9 \ud83d\ude00 a/b \u0001\t"}'
W=$(cat <<'EOF'
{
  "user": {
    "name": "Ana",
    "id": 1.0
  },
  "exp": 12345678901234567890,
  "big": 1e5,
  "neg": -0.5E-3,
  "u": "café 😀 a/b \u0001\t"
}
EOF
)
eq format-json-order-numbers-unicode "$W" format-json --text "$J"
eq format-json-indent4-sort $'{\n    "a": [\n        1,\n        {}\n    ],\n    "b": {\n        "c": [],\n        "d": null\n    }\n}' format-json indent=4 sort=true --text '{"b":{"d":null,"c":[]},"a":[1,{}]}'
eq format-json-tab $'{\n\t"a": true\n}' format-json indent=tab --text '{"a":true}'
eq format-json-empty '' format-json --text '   '
eq format-json-err-comma 'error: Invalid JSON at line 3, column 3: expected , or }.' format-json --text $'{\n  "a": 1\n  "b": 2\n}'
eq format-json-err-eof 'error: Invalid JSON at line 1, column 6: expected , or ].' format-json --text '[1, 2'
eq format-json-err-unicode-col 'error: Invalid JSON at line 1, column 7: expected a value.' format-json --text '{"é": x}'
eq format-json-err-trailing 'error: Invalid JSON at line 1, column 9: expected a key.' format-json --text '{"a": 1,}'
eq format-json-err-extra 'error: Invalid JSON at line 1, column 4: expected end of input.' format-json --text '{} {}'
eq minify-json-order '{"z":1,"a":{"y":[1,2.50,"x"],"b":null},"a":2}' minify-json --text $'{ "z": 1,\n "a": {"y": [1, 2.50, "x"], "b": null},\n "a": 2 }'
m1=$(out minify-json --text "$J"); m2=$(out format-json --text "$J" | "$CLI" minify-json)
same json-format-minify-trip "$m1" "$m2"
same json-minify-format-trip "$W" "$(out format-json --text "$m1")"
eq sort-json-nested $'{\n  "a": [\n    {\n      "x": 2,\n      "y": 1\n    }\n  ],\n  "b": {\n    "c": 2,\n    "d": 1\n  }\n}' sort-json --text '{"b":{"d":1,"c":2},"a":[{"y":1,"x":2}]}'

# MARK: YAML
YJ='{"name":"svc","on":"true","port":8080,"ratio":1.0,"tags":["a","2",null],"env":{"NODE_ENV":"production"},"empty":{},"list":[]}'
W=$(cat <<'EOF'
name: svc
'on': 'true'
port: 8080
ratio: 1.0
tags:
- a
- '2'
- null
env:
  NODE_ENV: production
empty: {}
list: []
EOF
)
eq json-to-yaml "$W" json-to-yaml --text "$YJ"
same json-yaml-json-trip "$(out minify-json --text "$YJ")" "$(out json-to-yaml --text "$YJ" | "$CLI" yaml-to-json | "$CLI" minify-json)"
Y=$'base: &b\n  x: 1\n  y: 2\nc:\n  <<: *b\n  y: 3\nlist: [*b]\n---\nk: 0x1F\nf: 1e3\nd: 2026-01-01\nq: "yes"\nb: yes\nn: ~'
same yaml-to-json-multidoc-anchors '[{"base":{"x":1,"y":2},"c":{"x":1,"y":3},"list":[{"x":1,"y":2}]},{"k":31,"f":1e3,"d":"2026-01-01","q":"yes","b":true,"n":null}]' "$(mj "$Y" yaml-to-json)"
eq yaml-to-json-single $'{\n  "a": 1\n}' yaml-to-json --text 'a: 1'
eq yaml-to-json-error 'error: Invalid YAML at line 1, column 5: mapping values are not allowed in this context.' yaml-to-json --text 'a: b: c'
eq yaml-to-json-alias-error 'error: Invalid YAML at line 1, column 4: found undefined alias.' yaml-to-json --text 'a: *x'

# MARK: CSV
CJ='[{"id":1,"name":"A, B","tags":["x"],"q":"say \"hi\""},{"id":2,"extra":null,"note":"line1\nline2"}]'
eq json-to-csv $'id,name,tags,q,extra,note\n1,"A, B","[""x""]","say ""hi""",,\n2,,,,,"line1\nline2"' json-to-csv --text "$CJ"
eq json-to-csv-tab $'a\tb\n1\t"x\ty"' json-to-csv delimiter=tab --text '[{"a":1,"b":"x\ty"}]'
eq json-to-csv-rows $'1,2\n3,"a,b"' json-to-csv --text '[[1,2],[3,"a,b"]]'
eq json-to-csv-error 'error: Paste a JSON array of objects.' json-to-csv --text '"x"'
RT='[{"id":1,"name":"A, B","note":"l1\nl2","q":"say \"hi\"","n":"007x"},{"id":-2.5,"name":"C","note":"","q":"","n":""}]'
same json-csv-json-trip "$(out minify-json --text "$RT")" "$(out json-to-csv --text "$RT" | "$CLI" csv-to-json numbers=true | "$CLI" minify-json)"
eq csv-to-json-quotes $'[\n  {\n    "a": "1",\n    "b": "x \\"q\\"\\nnext"\n  }\n]' csv-to-json --text $'a,b\r\n1,"x ""q""\nnext"\r\n'
same csv-to-json-semicolon-auto '[{"a":"1","b":"x;y"}]' "$(mj $'a;b\n1;"x;y"\n' csv-to-json)"
same csv-to-json-noheader '[["a","b"],["1",""]]' "$(mj $'a,b\n1,' csv-to-json header=false)"
same csv-to-json-ragged '[{"a":"1","b":""},{"a":"1","b":"2","column3":"3"}]' "$(mj $'a,b\n1\n\n1,2,3' csv-to-json)"
eq csv-to-json-unclosed 'error: Unclosed quote starting on line 2.' csv-to-json --text $'a,b\n"open,1\n'

# MARK: Query strings
eq query-to-json-url $'{\n  "a": [\n    "1",\n    "2"\n  ],\n  "b": "hello world",\n  "c": "✓",\n  "d": "",\n  "t": [\n    "x"\n  ]\n}' query-to-json --text 'https://x.com/p?a=1&b=hello+world&a=2&c=%E2%9C%93&d&t[]=x#frag'
same query-to-json-bare '{"q":"graphql cms","page":"2"}' "$(mj '?q=graphql%20cms&page=2' query-to-json)"
eq json-to-query 'a=1&a=2&b=hello%20world&c=%E2%9C%93&n[x]=1&z=' json-to-query --text '{"a":["1",2],"b":"hello world","c":"✓","n":{"x":1},"z":null}'
QS='a=1&a=2&b=hello%20world&c=%E2%9C%93&e=%26%3D'
same query-json-query-trip "$QS" "$(out query-to-json --text "$QS" | "$CLI" json-to-query)"
eq json-to-query-error 'error: Paste a JSON object.' json-to-query --text '[1]'

# MARK: XML
X='<?xml version="1.0"?><root a="1"><b>text &amp; more</b><c/><!-- note --><e><f>1</f></e></root>'
W=$(cat <<'EOF'
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<root a="1">
  <b>text &amp; more</b>
  <c/>
  <!-- note -->
  <e>
    <f>1</f>
  </e>
</root>
EOF
)
eq format-xml "$W" format-xml --text "$X"
eq format-xml-indent4 $'<r>\n    <a>1</a>\n</r>' format-xml indent=4 --text '<r><a>1</a></r>'
eq minify-xml '<root><b>text</b><c/><e><f>1</f></e></root>' minify-xml --text $'<root>\n  <b>text</b>\n  <c/>\n  <e>\n    <f>1</f>\n  </e>\n</root>'
same xml-format-minify-trip "$W" "$(out format-xml --text "$X" | "$CLI" minify-xml | "$CLI" format-xml)"
eq minify-xml-cdata '<a><![CDATA[x < y]]></a>' minify-xml --text $'<a>\n <![CDATA[x < y]]>\n</a>'
eq format-xml-error 'error: Invalid XML at line 1: Opening and ending tag mismatch: b line 1 and root.' format-xml --text '<root><b></root>'

# MARK: SQL
SQL=$(cat <<'EOF'
with recent as (select id, created_at from orders where created_at > now() - interval '7 days') select o.id, u.email as "User Email", count(*) filter (where o.total > 10) as big, row_number() over (partition by u.id order by o.created_at desc) rn, o.meta->>'k', o.id::text, 'it''s -- not a comment select from' as s, $$ select * from x where a and b $$ body
from recent r left outer join orders o on o.id = r.id and o.deleted_at is null join users u using (id) -- trailing note
where o.total between 1 and 100 and (u.role = 'admin' or u.role = $1) and u.id in (select user_id from bans) /* block */ and x = -1
group by o.id, u.email having count(*) > 1 order by o.id desc limit 10 offset 5;
insert into t (a, b) values ($1, E'a\'b'), (2, 'x') on conflict (a) do update set b = excluded.b, c = 1 returning *;
update users set name = 'x', updated_at = now() where id = $2;
delete from sessions where expires_at < now() returning id
EOF
)
W=$(cat <<'EOF'
WITH recent AS (
  SELECT
    id,
    created_at
  FROM orders
  WHERE created_at > NOW() - INTERVAL '7 days'
)
SELECT
  o.id,
  u.email AS "User Email",
  COUNT(*) FILTER (WHERE o.total > 10) AS big,
  row_number() OVER (PARTITION BY u.id ORDER BY o.created_at DESC) rn,
  o.meta ->> 'k',
  o.id::text,
  'it''s -- not a comment select from' AS s,
  $$ select * from x where a and b $$ body
FROM recent r
LEFT OUTER JOIN orders o ON o.id = r.id
  AND o.deleted_at IS NULL
JOIN users u USING (id) -- trailing note
WHERE o.total BETWEEN 1 AND 100
  AND (u.role = 'admin' OR u.role = $1)
  AND u.id IN (
    SELECT
      user_id
    FROM bans
  ) /* block */
  AND x = -1
GROUP BY o.id, u.email
HAVING COUNT(*) > 1
ORDER BY o.id DESC
LIMIT 10
OFFSET 5;

INSERT INTO t (a, b)
VALUES
  ($1, E'a\'b'),
  (2, 'x')
ON CONFLICT (a) DO UPDATE
SET
  b = excluded.b,
  c = 1
RETURNING *;

UPDATE users
SET
  name = 'x',
  updated_at = NOW()
WHERE id = $2;

DELETE FROM sessions
WHERE expires_at < NOW()
RETURNING id
EOF
)
F=$(out format-sql --text "$SQL")
same format-sql "$W" "$F"
same format-sql-idempotent "$F" "$(out format-sql --text "$F")"
lits=yes
for lit in "'7 days'" '"User Email"' "'it''s -- not a comment select from'" '$$ select * from x where a and b $$' "E'a\\'b'" "'k'"; do
  [[ "$F" == *"$lit"* && "$(out minify-sql --text "$SQL")" == *"$lit"* ]] || lits=no
done
ok sql-literals-intact $lits
NC=$(print -r -- "$SQL" | sed -e 's/ -- trailing note//' -e 's| /\* block \*/||')
same sql-minify-format-trip "$(out format-sql --text "$NC")" "$(out minify-sql --text "$SQL" | "$CLI" format-sql)"
eq minify-sql "select a,b from t where x = 'a  b' and y = -1 and z::int > \$1" minify-sql --text $'select a,  b\n-- note\nfrom t /* c */ where x = \'a  b\'\n  and y = -1 and z::int > $1'
eq format-sql-lowercase $'select\n  a\nfrom t\nwhere x = 1\n  and y between 2 and 3' format-sql upper=false --text 'select a from t where x=1 and y between 2 and 3'
eq format-sql-dollar-tag $'SELECT\n  $fn$ select 1; -- x $fn$' format-sql --text 'select $fn$ select 1; -- x $fn$'
eq format-sql-for-update $'SELECT\n  id\nFROM jobs\nWHERE status = \'queued\'\nORDER BY id FOR UPDATE SKIP LOCKED' format-sql --text "select id from jobs where status = 'queued' order by id for update skip locked"
eq format-sql-unclosed 'error: Unclosed string starting on line 2.' format-sql --text $'select 1\nwhere a = \'x'

# MARK: GraphQL
OP=$(cat <<'EOF'
# Fetch posts
query Posts($first: Int = 10, $where: PostWhereInput!, $stage: Stage = PUBLISHED, $locales: [Locale!]!, $skip: Boolean) @cached(ttl: 60) {
  posts(first: $first, where: $where, stage: $stage, locales: $locales, orderBy: publishedAt_DESC) { id
    t: title # the title
    author { ...AuthorFields @include(if: $skip) }
    ... on Post { slug content { html } }
    ... @skip(if: $skip) { createdAt }
    seo(filter: {tags: ["a", "b"], nested: {x: 1.5, y: null}}, text: "a \"q\" , b # not a comment")
  }
}
fragment AuthorFields on Author { name, bio }
mutation { publishPost(where: {id: "x"}, to: PUBLISHED) { id } }
EOF
)
W=$(cat <<'EOF'
# Fetch posts
query Posts(
  $first: Int = 10
  $where: PostWhereInput!
  $stage: Stage = PUBLISHED
  $locales: [Locale!]!
  $skip: Boolean
) @cached(ttl: 60) {
  posts(
    first: $first
    where: $where
    stage: $stage
    locales: $locales
    orderBy: publishedAt_DESC
  ) {
    id
    t: title # the title
    author {
      ...AuthorFields @include(if: $skip)
    }
    ... on Post {
      slug
      content {
        html
      }
    }
    ... @skip(if: $skip) {
      createdAt
    }
    seo(
      filter: { tags: ["a", "b"], nested: { x: 1.5, y: null } }
      text: "a \"q\" , b # not a comment"
    )
  }
}

fragment AuthorFields on Author {
  name
  bio
}

mutation {
  publishPost(where: { id: "x" }, to: PUBLISHED) {
    id
  }
}
EOF
)
F=$(out format-graphql --text "$OP")
same format-graphql-operation "$W" "$F"
same format-graphql-idempotent "$F" "$(out format-graphql --text "$F")"
same graphql-minify-format-trip "$(print -r -- "$F" | grep -v '^#' | sed 's/ # the title//')" "$(out minify-graphql --text "$OP" | "$CLI" format-graphql)"
eq minify-graphql 'query Q($a:Int=1){a:b(x:$a s:"x , # y"b:"""keep  this""")@skip(if:false){...F...on T{c}}}' minify-graphql --text $'query Q($a: Int = 1) {\n  # drop me\n  a: b(x: $a, s: "x , # y", b: """keep  this""") @skip(if: false) { ...F, ... on T { c } }\n}'
SDL=$(cat <<'EOF'
schema { query: Query mutation: Mutation }
"""
  A blog post.
    Indented line.
"""
type Post implements Node & Entity @key(fields: "id") {
  "The id" id: ID!
  title(locale: Locale = en, "fallback?" fallback: Boolean): String @deprecated(reason: "use name")
  tags: [String!]!
  # comment above author
  author: Author
}
input PostWhereInput { id: ID, title_contains: String = "x", AND: [PostWhereInput!] }
enum Stage { "Draft" DRAFT PUBLISHED @deprecated }
union SearchResult = Post | Author | Page | AVeryLongTypeNameNumberOne | AVeryLongTypeNameNumberTwo | More
union Small = A | B
scalar DateTime @specifiedBy(url: "https://tools.ietf.org/html/rfc3339")
directive @cached(ttl: Int = 60) repeatable on FIELD | QUERY
extend type Query { posts: [Post!]! }
interface Node { id: ID! }
EOF
)
W=$(cat <<'EOF'
schema {
  query: Query
  mutation: Mutation
}

"""
A blog post.
  Indented line.
"""
type Post implements Node & Entity @key(fields: "id") {
  "The id"
  id: ID!
  title(
    locale: Locale = en
    "fallback?"
    fallback: Boolean
  ): String @deprecated(reason: "use name")
  tags: [String!]!
  # comment above author
  author: Author
}

input PostWhereInput {
  id: ID
  title_contains: String = "x"
  AND: [PostWhereInput!]
}

enum Stage {
  "Draft"
  DRAFT
  PUBLISHED @deprecated
}

union SearchResult =
  | Post
  | Author
  | Page
  | AVeryLongTypeNameNumberOne
  | AVeryLongTypeNameNumberTwo
  | More

union Small = A | B

scalar DateTime @specifiedBy(url: "https://tools.ietf.org/html/rfc3339")

directive @cached(ttl: Int = 60) repeatable on FIELD | QUERY

extend type Query {
  posts: [Post!]!
}

interface Node {
  id: ID!
}
EOF
)
F=$(out format-graphql --text "$SDL")
same format-graphql-sdl "$W" "$F"
same format-graphql-sdl-idempotent "$F" "$(out format-graphql --text "$F")"
same graphql-sdl-minify-format-trip "$(print -r -- "$F" | grep -v '^ *#')" "$(out minify-graphql --text "$SDL" | "$CLI" format-graphql)"
eq format-graphql-comments $'{\n  a # one\n  # above b\n  b\n  # closing\n}\n\n# end' format-graphql --text $'{\n  a # one\n  # above b\n  b\n  # closing\n}\n# end'
eq format-graphql-error 'error: GraphQL syntax error at line 2, column 10: expected a name, found "}".' format-graphql --text $'query {\n  a(x: 1 }\n}'
eq format-graphql-lex-error 'error: GraphQL syntax error at line 1, column 9: unexpected character "é".' format-graphql --text 'query { é }'
eq minify-graphql-unterminated 'error: GraphQL syntax error at line 1, column 5: unterminated string.' minify-graphql --text '{ a "open }'
W=$(cat <<'EOF'
{
  "first": 10,
  "where": {},
  "stage": "PUBLISHED",
  "locales": [],
  "skip": false
}
EOF
)
eq graphql-variables "$W" graphql-variables --text "$OP"
same graphql-variables-types '{"s":"","i":0,"f":0.0,"id":"","dt":"","j":{},"o":"createdAt_DESC","l":"en","n":[1,"$x"]}' "$(mj 'query($s: String!, $i: Int, $f: Float!, $id: ID, $dt: DateTime, $j: Json, $o: PostOrderByInput, $l: Locale!, $n: [Int] = [1, $x]) { a }' graphql-variables)"
same graphql-variables-multi '{"A":{"a":0},"B":{"b":""}}' "$(mj 'query A($a: Int) { x } query B($b: ID) { y } mutation { z }' graphql-variables)"
eq graphql-variables-none 'error: No query, mutation or subscription found.' graphql-variables --text 'fragment F on T { a }'

# MARK: Codegen
GJ='{"id":42,"user_id":"u1","avatarURL":"https://x","createdAt":"2026-10-21T10:00:00Z","score":1.5,"tags":["a"],"meta":null,"items":[{"sku":"A","qty":1,"price":2},{"sku":"B","qty":2,"price":2.5,"note":"x","owner":null}],"profile":{"httpStatus":200,"first-name":"A","apiKey":"k"},"mixed":[1,"a"],"empty":[]}'
W=$(cat <<'EOF'
type Root struct {
	ID        int      `json:"id"`
	UserID    string   `json:"user_id"`
	AvatarURL string   `json:"avatarURL"`
	CreatedAt string   `json:"createdAt"`
	Score     float64  `json:"score"`
	Tags      []string `json:"tags"`
	Meta      any      `json:"meta"`
	Items     []Item   `json:"items"`
	Profile   Profile  `json:"profile"`
	Mixed     []any    `json:"mixed"`
	Empty     []any    `json:"empty"`
}

type Item struct {
	Sku   string  `json:"sku"`
	Qty   int     `json:"qty"`
	Price float64 `json:"price"`
	Note  string  `json:"note"`
	Owner any     `json:"owner"`
}

type Profile struct {
	HTTPStatus int    `json:"httpStatus"`
	FirstName  string `json:"first-name"`
	APIKey     string `json:"apiKey"`
}
EOF
)
eq json-to-go "$W" json-to-go --text "$GJ"
eq json-to-go-options $'import "time"\n\ntype Event []EventItem\n\ntype EventItem struct {\n\tAt   time.Time `json:"at,omitempty"`\n\tName *string   `json:"name,omitempty"`\n}' json-to-go root=event time=true omitempty=true --text '[{"at":"2026-10-21T10:00:00.123+02:00","name":"a"},{"at":"2026-10-21T10:00:00Z","name":null}]'
eq json-to-go-root-array $'type Root []int' json-to-go --text '[1,2]'
W=$(cat <<'EOF'
export interface Root {
  id: number;
  user_id: string;
  avatarURL: string;
  createdAt: string;
  score: number;
  tags: string[];
  meta: null;
  items: Item[];
  profile: Profile;
  mixed: (string | number)[];
  empty: unknown[];
}

export interface Item {
  sku: string;
  qty: number;
  price: number;
  note?: string;
  owner?: null;
}

export interface Profile {
  httpStatus: number;
  "first-name": string;
  apiKey: string;
}
EOF
)
eq json-to-typescript "$W" json-to-typescript --text "$GJ"
eq json-to-typescript-type $'export type Root = (string | number | RootItem)[];\n\nexport type RootItem = {\n  x: number | null;\n};' json-to-typescript style=type --text '[1,"a",{"x":1},{"x":null}]'
eq json-to-typescript-root $'export interface Payload {\n  a: boolean;\n}' json-to-typescript root=Payload --text '{"a":true}'

# MARK: Logs
LOG=$'2026-10-21T10:00:00Z INFO {"msg":"x","payload":"{\\"a\\":1,\\"b\\":\\"[1,2]\\"}"}\nplain line\nREPORT "{\\"k\\":true}"\nx {\\"esc\\":\\"y\\"} tail'
W=$(cat <<'EOF'
2026-10-21T10:00:00Z INFO {
  "msg": "x",
  "payload": {
    "a": 1,
    "b": [
      1,
      2
    ]
  }
}
plain line
REPORT {
  "k": true
}
x {
  "esc": "y"
} tail
EOF
)
eq unwrap-log-json "$W" unwrap-log-json --text "$LOG"
eq unwrap-log-json-blob $'{\n  "a": {\n    "b": 1\n  }\n}' unwrap-log-json --text $'{\n  "a": "{\\"b\\":1}"\n}'
eq unwrap-log-json-none 'no json here' unwrap-log-json --text 'no json here'

# MARK: JavaScript
eq evaluate-js-result $'hi {\n  "a": 1\n}\n[\n  2,\n  4\n]' evaluate-js --text 'console.log("hi", {a:1}); [1,2].map(x => x*2)'
eq evaluate-js-string 'ABC' evaluate-js --text '"abc".toUpperCase()'
eq evaluate-js-logs-only $'1\n2' evaluate-js --text 'for (let i = 1; i < 3; i++) console.log(i)'
eq evaluate-js-error 'error: Error: boom (line 2)' evaluate-js --text $'let x = 1;\nthrow new Error("boom")'
eq evaluate-js-syntax 'error: SyntaxError: Unexpected end of script (line 1)' evaluate-js --text 'foo('
eq evaluate-js-timeout 'error: Stopped after 1 second. Is there an endless loop?' evaluate-js --text 'while (true) {}'
eq evaluate-js-empty '' evaluate-js --text $'\n'

# MARK: Blank input gives blank output
for id in format-json minify-json sort-json json-to-yaml yaml-to-json json-to-csv csv-to-json query-to-json json-to-query \
  format-xml minify-xml format-sql minify-sql format-graphql minify-graphql graphql-variables json-to-go json-to-typescript \
  unwrap-log-json evaluate-js; do
  eq "$id-blank" '' $id --text $' \n'
done

echo "$pass passed, $fail failed"
[[ $fail -eq 0 ]]
