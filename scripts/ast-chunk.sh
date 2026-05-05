#!/usr/bin/env bash
# ast-chunk.sh — thin wrapper that invokes plan.js to produce AST-aware chunks.
#
# Contract (matches scripts/chunk-diff.awk):
#   Inputs:
#     $1: chunk size (lines, integer)
#     $2: output dir for chunks
#   Reads diff from stdin.
#   Writes chunk_001.diff ... chunk_NNN.diff plus chunk_count.txt to $2.
#
# Optional env:
#   PLAN_JSON_OUT   Path for plan.json output (default: <output_dir>/../plan.json)
#   AST_CHUNKER     Forces a specific mode: auto (default) | ast | hunk
#
# On any failure, exits non-zero. The caller (review.sh) should fall back to
# the awk chunker on non-zero exit and emit a stderr warning.

set -euo pipefail

if [[ $# -lt 2 ]]; then
  echo "Usage: ast-chunk.sh <chunk_size> <output_dir>" >&2
  exit 2
fi

chunk_size="$1"
output_dir="$2"
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
plan_js="$script_dir/plan.js"
awk_script="$script_dir/chunk-diff.awk"

if ! command -v node &>/dev/null; then
  echo "ast-chunk.sh: node not found on PATH" >&2
  exit 3
fi
if [[ ! -f "$plan_js" ]]; then
  echo "ast-chunk.sh: plan.js not found at $plan_js" >&2
  exit 3
fi

mkdir -p "$output_dir"
plan_out="${PLAN_JSON_OUT:-$output_dir/../plan.json}"
mode="${AST_CHUNKER:-auto}"

# Stash stdin as a real file so plan.js can read it.
tmp_diff="$(mktemp -t ast-chunk.XXXXXX.diff)"
trap 'rm -f "$tmp_diff"' EXIT
cat > "$tmp_diff"

node "$plan_js" \
  --diff "$tmp_diff" \
  --chunk-size "$chunk_size" \
  --chunks-dir "$output_dir" \
  --output "$plan_out" \
  --chunker "$mode" \
  --awk "$awk_script"

# Verify contract.
if [[ ! -f "$output_dir/chunk_count.txt" ]]; then
  echo "ast-chunk.sh: plan.js did not produce chunk_count.txt" >&2
  exit 3
fi
