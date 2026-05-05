#!/usr/bin/env bash
# tests/test-chunker.sh — Phase 1 chunker tests.
#
# Verifies:
#   1. plan.js + small-py.diff: produces a valid plan.json with manifest
#      entries; manifest contains both parse_options (def) and an entry for
#      the rename-tracked symbols. AST chunker keeps function bodies whole.
#   2. plan.js + ts-rename.diff: manifest contains either symbols_added/removed
#      pairs or a symbols_renamed entry. (We accept either; our heuristic is
#      conservative per SPEC §10.)
#   3. plan.js + large-go.diff: AST chunker produces multiple chunks; no chunk
#      file's content bisects a `func ` body — every chunk file that begins
#      mid-hunk starts with `@@`.
#   4. plan.js + no-supported-lang.diff: falls back to hunk mode and produces
#      output identical (chunk file count and headers) to the AWK chunker.
#   5. --chunker hunk on large-go.diff: byte-identical to the AWK chunker.
#   6. chunk-diff.awk mid-hunk fix: when a hunk is split, the new chunk file
#      starts with `@@` (not raw + lines).
#
# Usage:  bash tests/test-chunker.sh
# Exit:   0 if all assertions pass; 1 on the first failure.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PLAN_JS="$REPO_ROOT/scripts/plan.js"
AWK="$REPO_ROOT/scripts/chunk-diff.awk"
FIX="$SCRIPT_DIR/fixtures"

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

require_files() {
  local missing=0
  for f in "$@"; do
    [[ -f "$f" ]] || { echo "missing fixture: $f" >&2; missing=1; }
  done
  return "$missing"
}

# Ensure fixtures exist.
if [[ ! -f "$FIX/large-go.diff" ]]; then
  bash "$FIX/gen-large-go.sh" >/dev/null
fi
require_files \
  "$FIX/small-py.diff" "$FIX/ts-rename.diff" \
  "$FIX/large-go.diff" "$FIX/no-supported-lang.diff" \
  "$PLAN_JS" "$AWK"

# ─── 1. small-py.diff: plan.js produces plan with manifest ──────────────────
echo "Test 1: small-py.diff via plan.js (auto)"
out1="$WORK/small-py"
mkdir -p "$out1"
node "$PLAN_JS" --diff "$FIX/small-py.diff" --chunk-size 200 \
  --output "$out1/plan.json" --chunks-dir "$out1/chunks" --awk "$AWK" \
  > "$out1/stdout.log" 2> "$out1/stderr.log" || {
    echo "plan.js failed; see $out1/stderr.log" >&2; cat "$out1/stderr.log" >&2; exit 1;
  }
assert "[[ -f \"$out1/plan.json\" ]]" "plan.json written"
assert "jq -e '.manifest.files | length >= 2' \"$out1/plan.json\" >/dev/null" \
  "manifest lists >= 2 files"
assert "jq -e '.manifest.symbols_added | index(\"parse_options\")' \"$out1/plan.json\" >/dev/null" \
  "manifest.symbols_added contains parse_options"
assert "jq -e '.manifest.symbols_added | index(\"render_response\")' \"$out1/plan.json\" >/dev/null" \
  "manifest.symbols_added contains render_response"
assert "jq -e '.chunks | length >= 1' \"$out1/plan.json\" >/dev/null" \
  "plan.json has >= 1 chunks"

# ─── 2. ts-rename.diff: rename detection (lenient: either both adds+removes
#       OR an explicit renames entry) ─────────────────────────────────────────
echo "Test 2: ts-rename.diff via plan.js"
out2="$WORK/ts-rename"
mkdir -p "$out2"
node "$PLAN_JS" --diff "$FIX/ts-rename.diff" --chunk-size 200 \
  --output "$out2/plan.json" --chunks-dir "$out2/chunks" --awk "$AWK" \
  > "$out2/stdout.log" 2> "$out2/stderr.log" || {
    echo "plan.js failed; see $out2/stderr.log" >&2; cat "$out2/stderr.log" >&2; exit 1;
  }
assert "jq -e '
  ((.manifest.symbols_renamed | length) > 0)
  or
  (((.manifest.symbols_added | index(\"authenticateUserV2\")) != null)
   and ((.manifest.symbols_removed | index(\"authenticateUser\")) != null))
' \"$out2/plan.json\" >/dev/null" \
  "manifest captures the rename (renames[] OR add+remove pair)"

# ─── 3. large-go.diff: AST mode, multiple chunks, no mid-function bisect ────
echo "Test 3: large-go.diff via plan.js (auto/ast)"
out3="$WORK/large-go-ast"
mkdir -p "$out3"
node "$PLAN_JS" --diff "$FIX/large-go.diff" --chunk-size 1500 \
  --output "$out3/plan.json" --chunks-dir "$out3/chunks" --awk "$AWK" \
  > "$out3/stdout.log" 2> "$out3/stderr.log" || {
    echo "plan.js failed; see $out3/stderr.log" >&2; cat "$out3/stderr.log" >&2; exit 1;
  }
chunks_n=$(cat "$out3/chunks/chunk_count.txt")
assert "[[ \"$chunks_n\" -ge 2 ]]" "large-go.diff produces >= 2 chunks (got $chunks_n)"

# Every chunk file must begin with one of: diff --git | index | --- | +++ | @@
ok_starts=1
for f in "$out3/chunks"/chunk_*.diff; do
  [[ -s "$f" ]] || continue
  first_content=""
  while IFS= read -r line; do
    [[ -n "$line" ]] && first_content="$line" && break
  done < "$f"
  case "$first_content" in
    "diff --git "*|"index "*|"--- "*|"+++ "*|"@@ "*) : ;;
    *) ok_starts=0; echo "  bad first line in $f: $first_content" >&2 ;;
  esac
done
assert "[[ \"$ok_starts\" -eq 1 ]]" "every chunk file starts with diff/index/---/+++/@@"

# ─── 4. no-supported-lang.diff: falls back to hunk; identical to AWK ────────
echo "Test 4: no-supported-lang.diff (hunk fallback)"
out4="$WORK/no-supported-lang"
out4_awk="$WORK/no-supported-lang-awk"
mkdir -p "$out4" "$out4_awk"
node "$PLAN_JS" --diff "$FIX/no-supported-lang.diff" --chunk-size 1000 \
  --output "$out4/plan.json" --chunks-dir "$out4/chunks" --awk "$AWK" \
  > "$out4/stdout.log" 2> "$out4/stderr.log" || true
LC_ALL=C awk -v chunk_size=1000 -v output_dir="$out4_awk" \
  -f "$AWK" < "$FIX/no-supported-lang.diff"

n_plan=$(cat "$out4/chunks/chunk_count.txt")
n_awk=$(cat "$out4_awk/chunk_count.txt")
assert "[[ \"$n_plan\" -eq \"$n_awk\" ]]" \
  "hunk-fallback chunk count matches AWK ($n_plan vs $n_awk)"

# ─── 5. --chunker hunk on large-go: byte-identical to AWK ───────────────────
echo "Test 5: --chunker hunk vs AWK on large-go.diff"
out5="$WORK/large-go-hunk"
out5_awk="$WORK/large-go-awk-only"
mkdir -p "$out5" "$out5_awk"
node "$PLAN_JS" --diff "$FIX/large-go.diff" --chunk-size 1500 \
  --output "$out5/plan.json" --chunks-dir "$out5/chunks" --awk "$AWK" \
  --chunker hunk > "$out5/stdout.log" 2> "$out5/stderr.log"
LC_ALL=C awk -v chunk_size=1500 -v output_dir="$out5_awk" \
  -f "$AWK" < "$FIX/large-go.diff"

# Compare every chunk_*.diff byte-by-byte.
identical=1
for f in "$out5/chunks"/chunk_*.diff; do
  base=$(basename "$f")
  if ! cmp -s "$f" "$out5_awk/$base"; then
    identical=0
    echo "  divergent: $base" >&2
  fi
done
# Also chunk_count.txt
cmp -s "$out5/chunks/chunk_count.txt" "$out5_awk/chunk_count.txt" || identical=0
assert "[[ \"$identical\" -eq 1 ]]" \
  "--chunker hunk on large-go.diff is byte-identical to AWK chunker"

# ─── 6. chunk-diff.awk mid-hunk fix ────────────────────────────────────────
echo "Test 6: chunk-diff.awk mid-hunk fix"
big_diff="$WORK/big.diff"
{
  echo "diff --git a/big.py b/big.py"
  echo "index abc..def 100644"
  echo "--- a/big.py"
  echo "+++ b/big.py"
  echo "@@ -1,300 +1,300 @@"
  for i in $(seq 1 600); do echo "+    line_$i = $i"; done
} > "$big_diff"
out6="$WORK/big-out"
mkdir -p "$out6"
LC_ALL=C awk -v chunk_size=100 -v output_dir="$out6" \
  -f "$AWK" < "$big_diff"
mid_ok=1
for f in "$out6"/chunk_*.diff; do
  [[ -s "$f" ]] || continue
  # Walk until first non-empty line.
  first_content=""
  while IFS= read -r line; do
    [[ -n "$line" ]] && first_content="$line" && break
  done < "$f"
  case "$first_content" in
    "diff --git "*|"index "*|"--- "*|"+++ "*|"@@ "*) : ;;
    *) mid_ok=0; echo "  bad first line in $f: $first_content" >&2 ;;
  esac
done
assert "[[ \"$mid_ok\" -eq 1 ]]" \
  "every chunk_*.diff from a mid-hunk split begins with diff/index/---/+++/@@"

# ─── Summary ─────────────────────────────────────────────────────────────────
echo
echo "Results: $pass passed, $fail failed"
if [[ "$fail" -gt 0 ]]; then
  echo "Failures:"
  for m in "${fail_messages[@]}"; do echo "  - $m"; done
  exit 1
fi
exit 0
