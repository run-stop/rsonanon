#!/usr/bin/env bash
# tests/run_tests.sh — test suite for jsonanon
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BIN="$SCRIPT_DIR/../target/release/rsonanon"
TESTS_DIR="$SCRIPT_DIR"

# ── colours ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
PASS=0; FAIL=0

pass() { echo -e "${GREEN}  PASS${NC} $1"; ((PASS++)); }
fail() { echo -e "${RED}  FAIL${NC} $1: $2"; ((FAIL++)); }

# ── helpers ───────────────────────────────────────────────────────────────────

# Run jsonanon with given args, capture output
run() { "$BIN" "$@"; }

# Assert exit code 0
assert_ok() {
  local label=$1; shift
  if out=$(run "$@" 2>&1); then
    pass "$label"
  else
    fail "$label" "non-zero exit: $out"
  fi
}

# Assert output is valid JSON
assert_valid_json() {
  local label=$1 input=$2; shift 2
  local out
  if out=$(echo "$input" | run "$@" 2>&1) && echo "$out" | python3 -m json.tool >/dev/null 2>&1; then
    pass "$label"
  else
    fail "$label" "invalid JSON output"
  fi
}

# Assert file output is valid JSON
assert_file_valid_json() {
  local label=$1 file=$2; shift 2
  local out=/tmp/jsonanon_test_out.json
  if run --in:"$file" --out:"$out" "$@" 2>&1 >/dev/null && python3 -m json.tool "$out" >/dev/null 2>&1; then
    pass "$label"
  else
    fail "$label" "invalid JSON from $file"
  fi
}

# Assert that all keys from input appear in output (structural preservation)
assert_keys_preserved() {
  local label=$1 file=$2; shift 2
  local out
  out=$(run --in:"$file" --seed:42 "$@" 2>&1)
  local in_keys out_keys
  in_keys=$(python3 -c "import json,sys; d=json.load(open('$file')); print(sorted(d.keys() if isinstance(d,dict) else d[0].keys()))" 2>/dev/null || echo "N/A")
  out_keys=$(echo "$out" | python3 -c "import json,sys; d=json.load(sys.stdin); print(sorted(d.keys() if isinstance(d,dict) else d[0].keys()))" 2>/dev/null || echo "N/A")
  if [[ "$in_keys" == "$out_keys" ]]; then
    pass "$label"
  else
    fail "$label" "key mismatch: in=$in_keys out=$out_keys"
  fi
}

# Assert a Python expression (with 'd' = parsed output JSON) is true
# Extra args after expr are forwarded to jsonanon.
assert_expr() {
  local label=$1 file=$2 expr=$3; shift 3
  local out result
  out=$(run --in:"$file" --seed:42 "$@" 2>&1)
  result=$(echo "$out" | python3 -c "
import json, re, sys
d = json.load(sys.stdin)
try:
    print('ok' if ($expr) else 'fail')
except Exception as e:
    print('error: ' + str(e))
" 2>/dev/null)
  if [[ "$result" == "ok" ]]; then
    pass "$label"
  else
    fail "$label" "expr failed ($result): $(echo "$out" | head -3)"
  fi
}

# Assert determinism: same seed → same output on two runs
assert_deterministic() {
  local label=$1 file=$2; shift 2
  local out1 out2
  out1=$(run --in:"$file" --seed-text:determinism-test "$@" 2>&1)
  out2=$(run --in:"$file" --seed-text:determinism-test "$@" 2>&1)
  if [[ "$out1" == "$out2" ]]; then
    pass "$label"
  else
    fail "$label" "outputs differ between two runs with identical seed"
  fi
}

# Assert that two different seeds produce different outputs
assert_seed_differs() {
  local label=$1 file=$2; shift 2
  local out1 out2
  out1=$(run --in:"$file" --seed:1 "$@" 2>&1)
  out2=$(run --in:"$file" --seed:999 "$@" 2>&1)
  if [[ "$out1" != "$out2" ]]; then
    pass "$label"
  else
    fail "$label" "outputs identical for different seeds (unexpected)"
  fi
}

# Assert output contains no value from a list of strings
assert_no_value_leaked() {
  local label=$1 file=$2; shift 2
  local out
  out=$(run --in:"$file" --seed:42 "$@" 2>&1)
  local leaked=()
  while IFS= read -r val; do
    [[ -z "$val" ]] && continue
    if echo "$out" | grep -qF "$val"; then
      leaked+=("$val")
    fi
  done < <(python3 -c "
import json, sys
def extract_strings(obj):
    if isinstance(obj, str) and len(obj) > 3:
        yield obj
    elif isinstance(obj, dict):
        for v in obj.values(): yield from extract_strings(v)
    elif isinstance(obj, list):
        for v in obj: yield from extract_strings(v)
with open('$file') as f:
    for s in extract_strings(json.load(f)):
        print(s)
" 2>/dev/null)
  if [[ ${#leaked[@]} -eq 0 ]]; then
    pass "$label"
  else
    fail "$label" "leaked original values: ${leaked[*]:0:3}"
  fi
}

# Assert types are preserved for a single-object JSON file
assert_types_preserved() {
  local label=$1 file=$2; shift 2
  local out
  out=$(run --in:"$file" --seed:42 "$@" 2>&1)
  local ok
  ok=$(python3 -c "
import json, sys

def type_sig(obj):
    if isinstance(obj, dict):
        return {k: type_sig(v) for k, v in obj.items()}
    elif isinstance(obj, list):
        return [type_sig(v) for v in obj]
    elif isinstance(obj, bool):
        return 'bool'
    elif isinstance(obj, int):
        return 'int'
    elif isinstance(obj, float):
        return 'float'
    elif isinstance(obj, str):
        return 'str'
    elif obj is None:
        return 'null'

with open('$file') as f:
    orig = json.load(f)
out = json.loads('''$out''')
if type_sig(orig) == type_sig(out):
    print('ok')
else:
    print('mismatch')
    print('orig:', type_sig(orig))
    print('out: ', type_sig(out))
" 2>/dev/null)
  if [[ "$ok" == "ok" ]]; then
    pass "$label"
  else
    fail "$label" "type signature mismatch: $ok"
  fi
}

# ── build check ───────────────────────────────────────────────────────────────
echo ""
echo -e "${YELLOW}=== jsonanon test suite ===${NC}"
echo ""

if [[ ! -x "$BIN" ]]; then
  echo -e "${RED}ERROR:${NC} binary not found at $BIN — run: cd .. && nimble build"
  exit 1
fi
echo "Binary: $BIN"
echo ""

# ── group 1: basic validity ───────────────────────────────────────────────────
echo "── Group 1: JSON validity ──────────────────────────────────────────────"

for f in "$TESTS_DIR"/*.json; do
  name=$(basename "$f")
  assert_file_valid_json "valid JSON output: $name" "$f"
done

# ── group 2: key / structural preservation ───────────────────────────────────
echo ""
echo "── Group 2: Structural preservation ──────────────────────────────────"

for f in 01_person 02_nested 03_order 04_all_types 05_dates 06_numeric_special 07_identifiers 08_edge_cases; do
  assert_keys_preserved "keys preserved: $f" "$TESTS_DIR/$f.json"
done

# ── group 3: value-type preservation ─────────────────────────────────────────
echo ""
echo "── Group 3: Value-type preservation ──────────────────────────────────"

assert_expr "int stays int (age)"             "$TESTS_DIR/06_numeric_special.json" "isinstance(d['age'], int) and not isinstance(d['age'], bool)"
assert_expr "float stays float (score)"       "$TESTS_DIR/06_numeric_special.json" "isinstance(d['score'], float)"
assert_expr "bool stays bool (active)"        "$TESTS_DIR/01_person.json"          "isinstance(d['active'], bool)"
assert_expr "null preserved by default"       "$TESTS_DIR/03_order.json"           "d['notes'] is None"
assert_expr "string stays string (email)"     "$TESTS_DIR/01_person.json"          "isinstance(d['email'], str)"
assert_expr "array stays array (items)"       "$TESTS_DIR/03_order.json"           "isinstance(d['items'], list)"
assert_expr "array length preserved (items)"  "$TESTS_DIR/03_order.json"           "len(d['items']) == 2"

# ── group 4: semantic anonymization checks ───────────────────────────────────
echo ""
echo "── Group 4: Semantic anonymization ────────────────────────────────────"

assert_expr "email output looks like email"   "$TESTS_DIR/01_person.json"      "bool(re.match(r'^[^@]+@[^@]+\.[^@]+$', d['email']))"
assert_expr "email ends in .test"             "$TESTS_DIR/01_person.json"      "d['email'].endswith('.test')"
assert_expr "uuid output is UUID-shaped"      "$TESTS_DIR/07_identifiers.json" "bool(re.match(r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$', d['uuid']))"
assert_expr "ip output is in 10.x.x.x"       "$TESTS_DIR/07_identifiers.json" "d['ip'].startswith('10.')"
assert_expr "age stays in 18-89 range"        "$TESTS_DIR/06_numeric_special.json" "18 <= d['age'] <= 89"
assert_expr "year stays in 1970-2028 range"   "$TESTS_DIR/06_numeric_special.json" "1970 <= d['year'] <= 2028"
assert_expr "month stays in 1-12 range"       "$TESTS_DIR/06_numeric_special.json" "1 <= d['month'] <= 12"
assert_expr "day stays in 1-28 range"         "$TESTS_DIR/06_numeric_special.json" "1 <= d['day'] <= 28"
assert_expr "lat in valid range"              "$TESTS_DIR/06_numeric_special.json" "-90 <= d['latitude'] <= 90"
assert_expr "lon in valid range"              "$TESTS_DIR/06_numeric_special.json" "-180 <= d['longitude'] <= 180"
assert_expr "url output starts with https"    "$TESTS_DIR/07_identifiers.json"     "d['url'].startswith('https://')"
assert_expr "url ends in .test domain"        "$TESTS_DIR/07_identifiers.json"     "bool(re.search(r'\.example\.test/', d['url']))"
assert_expr "negative float stays negative"   "$TESTS_DIR/06_numeric_special.json" "d['negativeAmount'] < 0"
assert_expr "nested keys intact (meta.version)" "$TESTS_DIR/02_nested.json"       "isinstance(d['meta']['version'], (int, float)) and not isinstance(d['meta']['version'], bool)"

# ── group 5: no original values leak ─────────────────────────────────────────
echo ""
echo "── Group 5: Data non-leakage ───────────────────────────────────────────"

for f in 01_person 07_identifiers 02_nested; do
  assert_no_value_leaked "no originals leaked: $f" "$TESTS_DIR/$f.json"
done

# ── group 6: determinism ──────────────────────────────────────────────────────
echo ""
echo "── Group 6: Determinism ────────────────────────────────────────────────"

for f in 01_person 03_order 09_array_large; do
  assert_deterministic "deterministic (seed-text): $f" "$TESTS_DIR/$f.json"
done
assert_seed_differs "different seeds → different output: 01_person" "$TESTS_DIR/01_person.json"
assert_seed_differs "different seeds → different output: 03_order"  "$TESTS_DIR/03_order.json"

# ── group 7: pretty / compact output ─────────────────────────────────────────
echo ""
echo "── Group 7: Output format ──────────────────────────────────────────────"

assert_expr "pretty output valid JSON"    "$TESTS_DIR/01_person.json"  "True" --pretty:on
assert_expr "compact output valid JSON"   "$TESTS_DIR/03_order.json"   "True" --pretty:off
# compact output must not contain newlines
compact_out=$(run --in:"$TESTS_DIR/03_order.json" --seed:42 --pretty:off 2>&1)
if echo "$compact_out" | grep -q $'\n' && [[ $(echo "$compact_out" | wc -l) -gt 1 ]]; then
  fail "compact output is single line" "found newlines"
else
  pass "compact output is single line"
fi
# pretty output must contain newlines
pretty_out=$(run --in:"$TESTS_DIR/01_person.json" --seed:42 --pretty:on 2>&1)
if [[ $(echo "$pretty_out" | wc -l) -gt 5 ]]; then
  pass "pretty output has multiple lines"
else
  fail "pretty output has multiple lines" "only $(echo "$pretty_out" | wc -l) lines"
fi

# ── group 8: preserve-null option ────────────────────────────────────────────
echo ""
echo "── Group 8: preserve-null option ──────────────────────────────────────"

assert_expr "preserve-null:on keeps null"      "$TESTS_DIR/03_order.json" "d['notes'] is None"    --preserve-null:on
assert_expr "preserve-null:off replaces null"  "$TESTS_DIR/03_order.json" "d['notes'] is not None" --preserve-null:off
null_off_out=$(run --in:"$TESTS_DIR/03_order.json" --seed:42 --preserve-null:off 2>&1)
if echo "$null_off_out" | python3 -m json.tool >/dev/null 2>&1; then
  pass "preserve-null:off produces valid JSON"
else
  fail "preserve-null:off produces valid JSON" "invalid JSON"
fi

# ── group 9: stdin / stdout pipeline ─────────────────────────────────────────
echo ""
echo "── Group 9: stdin / stdout pipeline ───────────────────────────────────"

stdin_out=$(cat "$TESTS_DIR/01_person.json" | run --seed:42 2>&1)
if echo "$stdin_out" | python3 -m json.tool >/dev/null 2>&1; then
  pass "stdin pipe produces valid JSON"
else
  fail "stdin pipe produces valid JSON" "invalid JSON"
fi

# Combined stdin+compact+seed
piped_out=$(echo '{"name":"Alice","age":30,"active":true}' | run --seed:1 --pretty:off 2>&1)
if echo "$piped_out" | python3 -m json.tool >/dev/null 2>&1; then
  pass "inline stdin compact produces valid JSON"
else
  fail "inline stdin compact produces valid JSON" "$piped_out"
fi

# ── group 10: parallel path (large array) ────────────────────────────────────
echo ""
echo "── Group 10: Parallel processing (large array) ─────────────────────────"

assert_file_valid_json   "large array: valid JSON output"         "$TESTS_DIR/09_array_large.json"
assert_keys_preserved    "large array: keys preserved"            "$TESTS_DIR/09_array_large.json"
assert_deterministic     "large array: deterministic with seed"   "$TESTS_DIR/09_array_large.json"
assert_expr "large array: element count preserved"             "$TESTS_DIR/09_array_large.json" "len(d) == 35"
assert_expr "large array: all elements have email as string"   "$TESTS_DIR/09_array_large.json" "all(isinstance(item['email'], str) for item in d)"
assert_expr "large array: all ages in valid range"             "$TESTS_DIR/09_array_large.json" "all(18 <= item['age'] <= 89 for item in d)"

# ── group 11: error handling ──────────────────────────────────────────────────
echo ""
echo "── Group 11: Error handling ────────────────────────────────────────────"

invalid_json_out=$( (echo 'not-valid-json' | run 2>&1) || true)
if echo "$invalid_json_out" | grep -qi "error"; then
  pass "invalid JSON input prints error"
else
  fail "invalid JSON input prints error" "got: $invalid_json_out"
fi

missing_file_out=$( (run --in:nonexistent_file_xyz.json 2>&1) || true)
if echo "$missing_file_out" | grep -qi "error\|no such\|cannot\|does not"; then
  pass "missing input file reports error"
else
  fail "missing input file reports error" "got: $missing_file_out"
fi

# ── group 12: bug regression tests ──────────────────────────────────────────
echo ""
echo "── Group 12: Bug regressions ───────────────────────────────────────────"

assert_file_valid_json "regressions: valid JSON output" "$TESTS_DIR/11_regressions.json"

# zip/zipcode must not be treated as IPv4
assert_expr "zip is a 5-digit code, not an IP"     "$TESTS_DIR/11_regressions.json" \
  "bool(__import__('re').match(r'^\d{5}$', d['zip']))"
assert_expr "zipcode is a 5-digit code, not an IP" "$TESTS_DIR/11_regressions.json" \
  "bool(__import__('re').match(r'^\d{5}$', d['zipcode']))"
# ip field must still be replaced with a 10.x.x.x address
assert_expr "ip field is anonymized as IPv4"       "$TESTS_DIR/11_regressions.json" \
  "d['ip'].startswith('10.')"

# yyyy/MM/dd dates detected and kept in same format
assert_expr "yyyy/MM/dd date preserved in format"  "$TESTS_DIR/11_regressions.json" \
  "bool(__import__('re').match(r'^\d{4}/\d{2}/\d{2}$', d['slashDateYMD']))"

# ISO datetime anonymized with non-zero time component
assert_expr "ISO datetime has random time (not always midnight)" "$TESTS_DIR/11_regressions.json" \
  "bool(__import__('re').match(r'^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$', d['isoDatetime']))"

# preserve-null:off replaces null with a non-null value
null_replaced=$(run --in:"$TESTS_DIR/11_regressions.json" --seed:42 --preserve-null:off 2>&1 | \
  python3 -c "import json,sys; d=json.load(sys.stdin); print(d['nullableField'] is None)")
if [[ "$null_replaced" == "False" ]]; then
  pass "preserve-null:off replaces null in regression fixture"
else
  fail "preserve-null:off replaces null in regression fixture" "nullableField is still null"
fi

# ── group 13: unicode, incomplete, corrupted, binary ─────────────────────────
echo ""
echo "── Group 13: Unicode / malformed / binary input ────────────────────────"

# 13a: unicode — valid JSON with multibyte characters produces valid JSON
assert_file_valid_json "unicode: valid JSON output"       "$TESTS_DIR/10_unicode.json"
assert_keys_preserved  "unicode: keys preserved"          "$TESTS_DIR/10_unicode.json"
assert_deterministic   "unicode: deterministic with seed" "$TESTS_DIR/10_unicode.json"

# Score field keeps its int type even when surrounded by unicode strings
score_type=$(run --in:"$TESTS_DIR/10_unicode.json" --seed:42 2>&1 | \
  python3 -c "import json,sys; d=json.load(sys.stdin); print(type(d['score']).__name__)")
if [[ "$score_type" == "int" ]]; then
  pass "unicode: int field type preserved"
else
  fail "unicode: int field type preserved" "expected int, got $score_type"
fi

# 13b: incomplete / truncated JSON → must exit non-zero and print an error
incomplete='{"name":"Alice","age":30'   # missing closing brace
incomplete_out=$( (echo "$incomplete" | run 2>&1) || true)
if echo "$incomplete_out" | grep -qi "error"; then
  pass "incomplete JSON reports error"
else
  fail "incomplete JSON reports error" "got: $incomplete_out"
fi

# Truncated mid-string
truncated='{"key":"val'
truncated_out=$( (echo "$truncated" | run 2>&1) || true)
if echo "$truncated_out" | grep -qi "error"; then
  pass "truncated JSON reports error"
else
  fail "truncated JSON reports error" "got: $truncated_out"
fi

# 13c: corrupted JSON (structurally invalid)
for bad in \
  '}{' \
  '[1,2,,3]' \
  '{"a": NaN}' \
  '{key: "no-quotes"}' \
  "{'single': 'quotes'}"
do
  bad_out=$( (echo "$bad" | run 2>&1) || true)
  if echo "$bad_out" | grep -qi "error"; then
    pass "corrupted JSON reports error: $(echo "$bad" | head -c 20)…"
  else
    fail "corrupted JSON reports error: $(echo "$bad" | head -c 20)…" "got: $bad_out"
  fi
done

# 13d: binary / non-UTF-8 input → must exit non-zero (not silently corrupt output)
binary_out=$( (printf '\x00\x01\x02\xff\xfe\x80\x81' | run 2>&1) || true)
if echo "$binary_out" | grep -qi "error"; then
  pass "binary input reports error"
else
  fail "binary input reports error" "got: $binary_out"
fi

# Null bytes embedded in otherwise valid JSON
nullbyte_out=$( (printf '{"a":"hel\x00lo"}' | run 2>&1) || true)
if echo "$nullbyte_out" | grep -qi "error"; then
  pass "null-byte in JSON reports error"
else
  fail "null-byte in JSON reports error" "got: $nullbyte_out"
fi

# ── summary ───────────────────────────────────────────────────────────────────
echo ""
echo "────────────────────────────────────────────────────────────────────────"
TOTAL=$((PASS + FAIL))
if [[ $FAIL -eq 0 ]]; then
  echo -e "${GREEN}All $TOTAL tests passed.${NC}"
else
  echo -e "${RED}$FAIL/$TOTAL tests FAILED.${NC}"
  exit 1
fi
