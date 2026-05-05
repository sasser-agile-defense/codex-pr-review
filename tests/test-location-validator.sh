#!/usr/bin/env bash
# tests/test-location-validator.sh — Phase 5 location validator unit tests.
#
# Verifies:
#   1. validated-findings-input.json + validated-findings-diff.txt: 3 surviving
#      findings (2 LLM + 1 deterministic, all with valid line ranges in diff
#      hunks). Drops:
#        - 2 findings with line numbers far outside any diff hunk
#        - 1 finding citing a file not in the diff
#        - 1 finding with empty body
#        - 1 finding with confidence_score 0.5 (below default 0.8)
#   2. maintainability-exception.json: a single maintainability finding whose
#      lines are outside any hunk but whose file IS in the diff — survives.
#   3. Empty findings array: passes through unchanged (no error).
#   4. Empty diff with non-empty findings: drops everything with a warning.
#   5. Drop reasons are summarized to stderr.
#   6. The >30% drop warning fires when 5/8 are dropped.
#
# Usage:  bash tests/test-location-validator.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SCRIPTS_DIR="$REPO_ROOT/scripts"
FIX="$SCRIPT_DIR/fixtures"

VALIDATOR="$SCRIPTS_DIR/location-validator.sh"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

pass=0
fail=0
fail_messages=()

assert() {
  local cond="$1"; shift
  local msg="$*"
  if eval "$cond"; then
    pass=$((pass + 1))
    printf '  ok  %s\n' "$msg"
  else
    fail=$((fail + 1))
    fail_messages+=("$msg")
    printf '  FAIL %s (cond: %s)\n' "$msg" "$cond"
  fi
}

# Sanity check that the validator script exists.
assert "[[ -x \"$VALIDATOR\" ]]" "location-validator.sh exists and is executable"

# ─── Test 1: standard 8-finding mixed input → 3 survive ─────────────────────
echo "Test 1: 8 mixed findings → 3 survivors"
in1="$FIX/validated-findings-input.json"
diff1="$FIX/validated-findings-diff.txt"
out1="$WORK/out1.json"
err1="$WORK/err1.txt"
THRESHOLD=0.8 bash "$VALIDATOR" "$in1" "$diff1" "$out1" 2> "$err1"
assert "[[ -s \"$out1\" ]]" "validator wrote output"
assert "jq empty \"$out1\" >/dev/null 2>&1" "output is valid JSON"
kept=$(jq '.findings | length' "$out1")
assert "[[ \"$kept\" == '3' ]]" "kept exactly 3 findings (got $kept)"

# Verify the right ones survived: titles include "Valid finding inside handler.go hunk",
# "Valid finding inside util.py hunk", "Valid deterministic finding".
assert "jq -e '[.findings[].title] | contains([\"Valid finding inside handler.go hunk\"])' \"$out1\" >/dev/null" \
  "handler.go valid survives"
assert "jq -e '[.findings[].title] | contains([\"Valid finding inside util.py hunk\"])' \"$out1\" >/dev/null" \
  "util.py valid survives"
assert "jq -e '[.findings[].title] | contains([\"Valid deterministic finding\"])' \"$out1\" >/dev/null" \
  "deterministic valid survives"

# Verify drop reasons surfaced to stderr.
assert "grep -q 'dropped 5/8 findings' \"$err1\"" "drop count reported (5/8)"
assert "grep -q 'file not in diff' \"$err1\"" "stderr lists 'file not in diff'"
assert "grep -q 'line outside hunks' \"$err1\"" "stderr lists 'line outside hunks'"
assert "grep -q 'empty body' \"$err1\"" "stderr lists 'empty body'"
assert "grep -q 'below threshold' \"$err1\"" "stderr lists 'below threshold'"

# 5/8 = 62.5% > 30% → warning expected.
assert "grep -q 'Warning: location validator dropped 5/8' \"$err1\"" \
  ">30% drop warning fires"

# Validator must NOT exit non-zero even on heavy drops.
# (We test indirectly: out1 was written, no non-zero exit propagated through 'set -uo pipefail'.)

# ─── Test 2: maintainability exception ──────────────────────────────────────
echo "Test 2: maintainability finding outside hunks but file in diff → survives"
in2="$FIX/maintainability-exception.json"
diff2="$FIX/maintainability-exception-diff.txt"
out2="$WORK/out2.json"
err2="$WORK/err2.txt"
THRESHOLD=0.8 bash "$VALIDATOR" "$in2" "$diff2" "$out2" 2> "$err2"
kept2=$(jq '.findings | length' "$out2")
assert "[[ \"$kept2\" == '1' ]]" "maintainability finding survived (got $kept2)"
assert "jq -e '.findings[0].category == \"maintainability\"' \"$out2\" >/dev/null" \
  "surviving finding is the maintainability one"

# ─── Test 3: empty findings array → passthrough ─────────────────────────────
echo "Test 3: empty findings array passes through unchanged"
in3="$WORK/in3.json"
out3="$WORK/out3.json"
cat > "$in3" <<'JSON'
{"findings": [], "overall_correctness": "correct", "overall_explanation": "", "overall_confidence_score": 1.0, "review_iteration": 1, "resolved_prior_findings": []}
JSON
THRESHOLD=0.8 bash "$VALIDATOR" "$in3" "$diff1" "$out3" 2> "$WORK/err3.txt"
kept3=$(jq '.findings | length' "$out3")
assert "[[ \"$kept3\" == '0' ]]" "empty findings array stays empty"
assert "jq -e '.overall_correctness == \"correct\"' \"$out3\" >/dev/null" \
  "non-findings fields preserved verbatim"

# ─── Test 4: empty diff + non-empty findings → drop all with warning ────────
echo "Test 4: empty diff + findings → drops all"
empty_diff="$WORK/empty.diff"
: > "$empty_diff"
out4="$WORK/out4.json"
err4="$WORK/err4.txt"
THRESHOLD=0.8 bash "$VALIDATOR" "$in1" "$empty_diff" "$out4" 2> "$err4"
kept4=$(jq '.findings | length' "$out4")
assert "[[ \"$kept4\" == '0' ]]" "all findings dropped when diff is empty"
assert "grep -q 'diff file is empty' \"$err4\"" "stderr warns about empty diff"

# ─── Test 5: missing code_location → drop with reason "no code_location" ─────
echo "Test 5: missing code_location drops with proper reason"
in5="$WORK/in5.json"
out5="$WORK/out5.json"
err5="$WORK/err5.txt"
cat > "$in5" <<'JSON'
{
  "findings": [
    {
      "title": "No location",
      "body": "should be dropped",
      "confidence_score": 0.95,
      "priority": 2,
      "status": "new"
    }
  ],
  "overall_correctness": "correct",
  "overall_explanation": "",
  "overall_confidence_score": 1.0,
  "review_iteration": 1,
  "resolved_prior_findings": []
}
JSON
THRESHOLD=0.8 bash "$VALIDATOR" "$in5" "$diff1" "$out5" 2> "$err5"
kept5=$(jq '.findings | length' "$out5")
assert "[[ \"$kept5\" == '0' ]]" "missing code_location finding dropped"
assert "grep -q 'no code_location' \"$err5\"" "stderr lists 'no code_location'"

# ─── Test 6: zero / negative start_line → drop ──────────────────────────────
echo "Test 6: zero/negative start_line drops"
in6="$WORK/in6.json"
out6="$WORK/out6.json"
err6="$WORK/err6.txt"
cat > "$in6" <<'JSON'
{
  "findings": [
    {
      "title": "Zero line",
      "body": "should be dropped",
      "confidence_score": 0.95,
      "priority": 2,
      "code_location": {"path": "src/handler.go", "start_line": 0, "end_line": 0},
      "status": "new"
    }
  ],
  "overall_correctness": "correct",
  "overall_explanation": "",
  "overall_confidence_score": 1.0,
  "review_iteration": 1,
  "resolved_prior_findings": []
}
JSON
THRESHOLD=0.8 bash "$VALIDATOR" "$in6" "$diff1" "$out6" 2> "$err6"
kept6=$(jq '.findings | length' "$out6")
assert "[[ \"$kept6\" == '0' ]]" "zero start_line finding dropped"
assert "grep -q 'bad start_line' \"$err6\"" "stderr lists 'bad start_line'"

# ─── Test 7: THRESHOLD env override ─────────────────────────────────────────
echo "Test 7: THRESHOLD=0.4 keeps the 0.5-confidence finding"
out7="$WORK/out7.json"
THRESHOLD=0.4 bash "$VALIDATOR" "$in1" "$diff1" "$out7" 2>"$WORK/err7.txt"
kept7=$(jq '.findings | length' "$out7")
assert "[[ \"$kept7\" == '4' ]]" "lowered threshold keeps 4 (3 + the 0.5-conf one) (got $kept7)"

# ─── Summary ─────────────────────────────────────────────────────────────────
echo
echo "Results: $pass passed, $fail failed"
if [[ "$fail" -gt 0 ]]; then
  echo "Failures:"
  for m in "${fail_messages[@]}"; do echo "  - $m"; done
  exit 1
fi
exit 0
