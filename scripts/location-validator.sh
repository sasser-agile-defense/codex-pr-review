#!/usr/bin/env bash
# scripts/location-validator.sh — v2 P5 deterministic post-synthesis filter.
#
# Reads a synthesis output (codex-output.json shape) plus the diff that the
# review was performed against, and drops findings that:
#   - point at a file not present in the diff;
#   - point at a line range entirely outside all diff hunks (with an exception
#     for category="maintainability" findings whose file IS in the diff);
#   - have empty body, missing confidence_score, or confidence_score < THRESHOLD;
#   - have a missing/zero/negative start_line, or no code_location.
#
# Usage:
#   location-validator.sh <input-output.json> <diff-file> <output-validated.json>
#
# Env:
#   THRESHOLD — confidence threshold (default 0.8). May also come from caller.
#
# Behavior on edge cases:
#   - If the input has zero findings, the output is the input verbatim.
#   - If > 30% of findings are dropped, a warning is printed to stderr but the
#     script still exits 0 — the caller posts anyway per spec §4.6.
#   - All drop reasons are summarized to stderr.
#
# Notes:
#   - This is a pure deterministic filter. No LLM calls, no network. The diff
#     hunk parser is in awk for portability.

set -euo pipefail

if [[ $# -lt 3 ]]; then
  echo "Usage: location-validator.sh <input-output.json> <diff-file> <output-validated.json>" >&2
  exit 2
fi

INPUT="$1"
DIFF="$2"
OUTPUT="$3"
THRESHOLD="${THRESHOLD:-0.8}"

if [[ ! -f "$INPUT" ]]; then
  echo "location-validator: input file not found: $INPUT" >&2
  exit 2
fi

if ! jq empty "$INPUT" 2>/dev/null; then
  echo "location-validator: input is not valid JSON: $INPUT" >&2
  exit 2
fi

# ─── Build the diff "shape": files in diff + per-file hunk ranges ────────────
# Output of this awk pass:
#   <file>\t<new_start>\t<new_count>\n   (one per hunk)
# Files with no hunks (binary diffs, pure renames) still emit one record:
#   <file>\t0\t0
# We use the b/<path> token from `diff --git` to canonicalize file names.
hunk_table="$(mktemp)"
trap 'rm -f "$hunk_table" "$hunk_table.files" "$hunk_table.findings_in" "$hunk_table.findings_out" "$hunk_table.summary" 2>/dev/null || true' EXIT

if [[ -f "$DIFF" && -s "$DIFF" ]]; then
  awk '
    function emit_file_marker(p) {
      # Mark presence of the file even if no hunks follow.
      printf "%s\t0\t0\n", p
    }
    /^diff --git / {
      cur_file = ""
      # Capture b/<path>. Must be space-anchored so that "lib/big.py" inside
      # "a/lib/big.py" does not match the inner "b/big.py" substring.
      if (match($0, /[[:space:]]b\/[^[:space:]]+/)) {
        cur_file = substr($0, RSTART+3, RLENGTH-3)
        emit_file_marker(cur_file)
      }
      next
    }
    /^@@ / {
      if (cur_file == "") next
      # Extract +start[,count] from the @@ header.
      if (match($0, /\+[0-9]+(,[0-9]+)?/)) {
        seg = substr($0, RSTART+1, RLENGTH-1)
        n = split(seg, parts, ",")
        ns = parts[1] + 0
        nc = (n >= 2 ? parts[2] + 0 : 1)
        printf "%s\t%d\t%d\n", cur_file, ns, nc
      }
      next
    }
  ' "$DIFF" > "$hunk_table"
else
  # Empty diff → no files, no hunks. All findings will be dropped.
  : > "$hunk_table"
fi

# Files-in-diff index (sorted unique). Used for the maintainability exception.
awk -F'\t' '{print $1}' "$hunk_table" | sort -u > "$hunk_table.files"

# Total findings count for the >30% drop heuristic.
total=$(jq '.findings | length' "$INPUT" 2>/dev/null || echo 0)
if [[ "$total" -eq 0 ]]; then
  # Empty findings array is a no-op: pass through unchanged.
  cp "$INPUT" "$OUTPUT"
  echo "location-validator: 0 findings (input unchanged)." >&2
  exit 0
fi

# Special-case: the diff is empty but findings exist. Drop everything with a
# noisy warning per the task spec.
if [[ ! -s "$hunk_table" ]]; then
  echo "location-validator: WARNING — diff file is empty (\"$DIFF\"); dropping all $total findings." >&2
  jq '.findings = []' "$INPUT" > "$OUTPUT"
  exit 0
fi

# ─── Walk findings, decide pass/drop, keep counters by reason ───────────────
# We emit a rebuilt JSON document with a filtered `findings` array. Counters
# are aggregated to stderr.

drop_no_loc=0
drop_bad_line=0
drop_file_missing=0
drop_outside_hunks=0
drop_empty_body=0
drop_missing_conf=0
drop_low_conf=0

# Read findings line-by-line as compact JSON objects.
jq -c '.findings[]' "$INPUT" > "$hunk_table.findings_in"

# Streaming filter loop. Each iteration writes either nothing (drop) or one
# compact JSON line to .findings_out.
: > "$hunk_table.findings_out"
while IFS= read -r f; do
  [[ -z "$f" ]] && continue

  # Field extraction. Use jq with `// empty` so we can distinguish present-empty
  # from absent.
  body=$(printf '%s' "$f" | jq -r '.body // ""' 2>/dev/null || echo "")
  if [[ -z "$body" ]]; then
    drop_empty_body=$((drop_empty_body + 1))
    continue
  fi

  has_conf=$(printf '%s' "$f" | jq 'has("confidence_score") and (.confidence_score != null)')
  if [[ "$has_conf" != "true" ]]; then
    drop_missing_conf=$((drop_missing_conf + 1))
    continue
  fi
  # Prefer the pre-penalty `original_confidence_score` for threshold gating
  # when present (set by the cross-family verifier merge for findings that
  # received the inconclusive penalty). Falls back to `confidence_score` for
  # confirmed findings, deterministic findings, and any v1-shaped output.
  # Without this fallback, every inconclusive finding (post-penalty conf
  # ≤ 0.7) is unwinnable against the default 0.8 threshold.
  conf=$(printf '%s' "$f" | jq -r '
    if has("original_confidence_score") and (.original_confidence_score != null)
    then .original_confidence_score
    else .confidence_score
    end
  ')
  # Numeric compare via awk for portability (bash can't compare floats).
  below=$(awk -v c="$conf" -v t="$THRESHOLD" 'BEGIN { print (c+0 < t+0) ? "1" : "0" }')
  if [[ "$below" == "1" ]]; then
    drop_low_conf=$((drop_low_conf + 1))
    continue
  fi

  has_loc=$(printf '%s' "$f" | jq 'has("code_location") and (.code_location != null)')
  if [[ "$has_loc" != "true" ]]; then
    drop_no_loc=$((drop_no_loc + 1))
    continue
  fi

  file_path=$(printf '%s' "$f" | jq -r '.code_location.path // ""')
  start_line=$(printf '%s' "$f" | jq -r '.code_location.start_line // 0')
  end_line=$(printf '%s' "$f"   | jq -r '.code_location.end_line   // 0')
  category=$(printf '%s' "$f"   | jq -r '.category // ""')

  if [[ -z "$file_path" ]]; then
    drop_no_loc=$((drop_no_loc + 1))
    continue
  fi

  # start_line must be a positive integer.
  if ! [[ "$start_line" =~ ^[0-9]+$ ]] || [[ "$start_line" -le 0 ]]; then
    drop_bad_line=$((drop_bad_line + 1))
    continue
  fi
  if ! [[ "$end_line" =~ ^[0-9]+$ ]] || [[ "$end_line" -le 0 ]]; then
    end_line="$start_line"
  fi
  if [[ "$end_line" -lt "$start_line" ]]; then
    end_line="$start_line"
  fi

  # File must be in the diff.
  if ! grep -Fxq "$file_path" "$hunk_table.files"; then
    drop_file_missing=$((drop_file_missing + 1))
    continue
  fi

  # Line-range must intersect at least one hunk for this file. The hunk_table
  # entry "<file>\t0\t0" is just the file-presence marker (no hunks); a hunk
  # has count > 0.
  in_hunk=0
  while IFS=$'\t' read -r hf hs hc; do
    [[ "$hf" != "$file_path" ]] && continue
    [[ "$hc" -le 0 ]] && continue
    # Hunk covers [hs, hs+hc-1]. Finding covers [start_line, end_line].
    # They intersect iff start_line <= hs+hc-1 AND end_line >= hs.
    local_end=$((hs + hc - 1))
    if [[ "$start_line" -le "$local_end" && "$end_line" -ge "$hs" ]]; then
      in_hunk=1
      break
    fi
  done < "$hunk_table"

  if [[ "$in_hunk" -eq 0 ]]; then
    # Maintainability exception: file is in diff (already verified above) and
    # category is maintainability → keep, even if line is outside hunks.
    if [[ "$category" == "maintainability" ]]; then
      printf '%s\n' "$f" >> "$hunk_table.findings_out"
      continue
    fi
    drop_outside_hunks=$((drop_outside_hunks + 1))
    continue
  fi

  printf '%s\n' "$f" >> "$hunk_table.findings_out"
done < "$hunk_table.findings_in"

kept=$(wc -l < "$hunk_table.findings_out" | tr -d ' ')
dropped=$((total - kept))

# ─── Build the output JSON: replace .findings with the kept array. ──────────
# jq --slurpfile reads the survivors as a single array.
if [[ "$kept" -eq 0 ]]; then
  jq '.findings = []' "$INPUT" > "$OUTPUT"
else
  jq --slurpfile s "$hunk_table.findings_out" '.findings = $s' "$INPUT" > "$OUTPUT"
fi

# ─── Stderr summary ─────────────────────────────────────────────────────────
{
  reasons=()
  [[ "$drop_no_loc"        -gt 0 ]] && reasons+=("$drop_no_loc no code_location")
  [[ "$drop_bad_line"      -gt 0 ]] && reasons+=("$drop_bad_line bad start_line")
  [[ "$drop_file_missing"  -gt 0 ]] && reasons+=("$drop_file_missing file not in diff")
  [[ "$drop_outside_hunks" -gt 0 ]] && reasons+=("$drop_outside_hunks line outside hunks")
  [[ "$drop_empty_body"    -gt 0 ]] && reasons+=("$drop_empty_body empty body")
  [[ "$drop_missing_conf"  -gt 0 ]] && reasons+=("$drop_missing_conf missing confidence_score")
  [[ "$drop_low_conf"      -gt 0 ]] && reasons+=("$drop_low_conf below threshold $THRESHOLD")

  if [[ "$dropped" -gt 0 ]]; then
    summary=$(IFS=,; printf '%s' "${reasons[*]}")
    echo "location-validator: dropped $dropped/$total findings (kept $kept). Reasons: $summary" >&2
  else
    echo "location-validator: kept $kept/$total findings." >&2
  fi

  # >30% threshold warning. We compute via awk so we don't need bc.
  if [[ "$total" -gt 0 ]]; then
    pct_over=$(awk -v d="$dropped" -v t="$total" 'BEGIN { print (d/t > 0.3) ? "1" : "0" }')
    if [[ "$pct_over" == "1" ]]; then
      echo "Warning: location validator dropped $dropped/$total findings (>30%)" >&2
    fi
  fi
} || true

exit 0
