#!/usr/bin/env bash
set -euo pipefail

# ─── Codex PR Review ─────────────────────────────────────────────────────────
# Orchestrates a PR code review using OpenAI Codex CLI.
# Usage: review.sh [PR_NUMBER|PR_URL] [--threshold FLOAT] [--model MODEL]
#                  [--max-diff-lines INT] [--chunk-size INT]
# ──────────────────────────────────────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK_DIR=$(mktemp -d)
trap 'rm -rf "$WORK_DIR"' EXIT

# ─── Defaults ─────────────────────────────────────────────────────────────────
THRESHOLD="0.8"
MODEL="gpt-5.3-codex"
MAX_DIFF_LINES="200000"
CHUNK_SIZE="5000"
PR_ARG=""

# ─── Arg Parsing ──────────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --threshold)
      THRESHOLD="$2"
      shift 2
      ;;
    --model)
      MODEL="$2"
      shift 2
      ;;
    --max-diff-lines)
      MAX_DIFF_LINES="$2"
      shift 2
      ;;
    --chunk-size)
      CHUNK_SIZE="$2"
      shift 2
      ;;
    -*)
      echo "Error: Unknown flag $1" >&2
      exit 1
      ;;
    *)
      PR_ARG="$1"
      shift
      ;;
  esac
done

# ─── Prerequisite Checks ─────────────────────────────────────────────────────
check_prereqs() {
  local missing=()

  if ! command -v codex &>/dev/null; then
    missing+=("codex CLI (install: npm install -g @openai/codex)")
  fi

  if ! command -v gh &>/dev/null; then
    missing+=("gh CLI (install: brew install gh)")
  fi

  if ! command -v jq &>/dev/null; then
    missing+=("jq (install: brew install jq)")
  fi

  if [[ ${#missing[@]} -gt 0 ]]; then
    echo "Error: Missing prerequisites:" >&2
    for m in "${missing[@]}"; do
      echo "  - $m" >&2
    done
    exit 1
  fi

  # Verify codex is authenticated via OAuth (headless mode requires OAuth, not API key)
  if ! codex login status &>/dev/null 2>&1; then
    echo "Error: codex CLI is not authenticated via OAuth. Run: codex login" >&2
    echo "Note: codex exec (headless mode) requires OAuth, not OPENAI_API_KEY." >&2
    exit 1
  fi

  # Verify gh is authenticated
  if ! gh auth status &>/dev/null 2>&1; then
    echo "Error: gh CLI is not authenticated. Run: gh auth login" >&2
    exit 1
  fi

  # Verify we're in a git repo
  if ! git rev-parse --is-inside-work-tree &>/dev/null 2>&1; then
    echo "Error: Not inside a git repository." >&2
    exit 1
  fi
}

# ─── PR Detection ─────────────────────────────────────────────────────────────
detect_pr() {
  local pr_json

  if [[ -n "$PR_ARG" ]]; then
    # Pass URLs directly to gh (supports cross-repo); extract number for plain integers
    local pr_ref="$PR_ARG"
    if [[ "$PR_ARG" =~ ^[0-9]+$ ]]; then
      pr_ref="$PR_ARG"
    fi
    pr_json=$(gh pr view "$pr_ref" --json number,title,headRefName,baseRefName,url 2>/dev/null) || {
      echo "Error: Could not find PR $PR_ARG" >&2
      exit 2
    }
  else
    # Auto-detect from current branch
    pr_json=$(gh pr view --json number,title,headRefName,baseRefName,url 2>/dev/null) || {
      echo "Error: No PR found for current branch. Specify a PR number: review.sh 123" >&2
      exit 2
    }
  fi

  echo "$pr_json"
}

# ─── CLAUDE.md Discovery ─────────────────────────────────────────────────────
gather_project_rules() {
  local repo_root
  repo_root=$(git rev-parse --show-toplevel 2>/dev/null || echo ".")
  local rules=""

  # Check repo root
  if [[ -f "$repo_root/CLAUDE.md" ]]; then
    rules+="## Project Rules (from CLAUDE.md)"$'\n\n'
    rules+="The project has the following rules that must be respected:"$'\n\n'
    rules+=$(cat "$repo_root/CLAUDE.md")
    rules+=$'\n\n'
  fi

  echo "$rules"
}

# ─── Build Prompt ─────────────────────────────────────────────────────────────
build_prompt() {
  local pr_number="$1"
  local pr_title="$2"
  local head_branch="$3"
  local base_branch="$4"
  local diff="$5"
  local project_rules="$6"

  local template
  template=$(cat "$SCRIPT_DIR/codex-prompt.md")

  # Template substitution
  local project_rules_section=""
  if [[ -n "$project_rules" ]]; then
    project_rules_section="$project_rules"
  fi

  template="${template//\{\{PROJECT_RULES\}\}/$project_rules_section}"
  template="${template//\{\{PR_NUMBER\}\}/$pr_number}"
  template="${template//\{\{PR_TITLE\}\}/$pr_title}"
  template="${template//\{\{HEAD_BRANCH\}\}/$head_branch}"
  template="${template//\{\{BASE_BRANCH\}\}/$base_branch}"
  template="${template//\{\{DIFF\}\}/$diff}"

  echo "$template"
}

# ─── Build Chunk Prompt ──────────────────────────────────────────────────────
build_chunk_prompt() {
  local pr_number="$1"
  local pr_title="$2"
  local head_branch="$3"
  local base_branch="$4"
  local diff="$5"
  local project_rules="$6"
  local chunk_num="$7"
  local total_chunks="$8"

  local template
  template=$(cat "$SCRIPT_DIR/codex-chunk-prompt.md")

  local project_rules_section=""
  if [[ -n "$project_rules" ]]; then
    project_rules_section="$project_rules"
  fi

  template="${template//\{\{PROJECT_RULES\}\}/$project_rules_section}"
  template="${template//\{\{PR_NUMBER\}\}/$pr_number}"
  template="${template//\{\{PR_TITLE\}\}/$pr_title}"
  template="${template//\{\{HEAD_BRANCH\}\}/$head_branch}"
  template="${template//\{\{BASE_BRANCH\}\}/$base_branch}"
  template="${template//\{\{DIFF\}\}/$diff}"
  template="${template//\{\{CHUNK_NUM\}\}/$chunk_num}"
  template="${template//\{\{TOTAL_CHUNKS\}\}/$total_chunks}"

  echo "$template"
}

# ─── Build Synthesis Prompt ──────────────────────────────────────────────────
build_synthesis_prompt() {
  local pr_number="$1"
  local pr_title="$2"
  local head_branch="$3"
  local base_branch="$4"
  local chunk_results="$5"
  local total_chunks="$6"

  local template
  template=$(cat "$SCRIPT_DIR/codex-synthesis-prompt.md")

  template="${template//\{\{PR_NUMBER\}\}/$pr_number}"
  template="${template//\{\{PR_TITLE\}\}/$pr_title}"
  template="${template//\{\{HEAD_BRANCH\}\}/$head_branch}"
  template="${template//\{\{BASE_BRANCH\}\}/$base_branch}"
  template="${template//\{\{CHUNK_RESULTS\}\}/$chunk_results}"
  template="${template//\{\{TOTAL_CHUNKS\}\}/$total_chunks}"

  echo "$template"
}

# ─── Review Single Chunk (background job) ────────────────────────────────────
review_chunk() {
  local chunk_file="$1"
  local chunk_num="$2"
  local total_chunks="$3"
  local pr_number="$4"
  local pr_title="$5"
  local head_branch="$6"
  local base_branch="$7"
  local project_rules="$8"
  local output_file="$9"

  local chunk_diff
  chunk_diff=$(cat "$chunk_file")

  local prompt
  prompt=$(build_chunk_prompt "$pr_number" "$pr_title" "$head_branch" "$base_branch" "$chunk_diff" "$project_rules" "$chunk_num" "$total_chunks")

  local prompt_file="$WORK_DIR/chunk-prompt-${chunk_num}.md"
  echo "$prompt" > "$prompt_file"

  if codex exec \
    --model "$MODEL" \
    --output-schema "$WORK_DIR/codex-output-schema.json" \
    --sandbox read-only \
    - < "$prompt_file" > "$output_file" 2>"$WORK_DIR/chunk-stderr-${chunk_num}.log"; then
    # Validate JSON
    if jq empty "$output_file" 2>/dev/null; then
      echo "  Chunk $chunk_num/$total_chunks completed." >&2
      return 0
    fi
  fi

  echo "  Chunk $chunk_num/$total_chunks FAILED." >&2
  return 1
}

# ─── Single Review Path ──────────────────────────────────────────────────────
run_single_review() {
  local pr_number="$1"
  local pr_title="$2"
  local head_branch="$3"
  local base_branch="$4"
  local diff="$5"
  local project_rules="$6"

  # Build prompt
  echo "Building review prompt..." >&2
  local prompt
  prompt=$(build_prompt "$pr_number" "$pr_title" "$head_branch" "$base_branch" "$diff" "$project_rules")
  echo "$prompt" > "$WORK_DIR/codex-prompt-filled.md"

  # Copy schema to work dir
  cp "$SCRIPT_DIR/codex-output-schema.json" "$WORK_DIR/"

  # Run Codex
  echo "Running Codex review (this may take a minute)..." >&2
  if ! codex exec \
    --model "$MODEL" \
    --output-schema "$WORK_DIR/codex-output-schema.json" \
    --sandbox read-only \
    - < "$WORK_DIR/codex-prompt-filled.md" > "$WORK_DIR/codex-output.json" 2>"$WORK_DIR/codex-stderr.log"; then
    echo "Error: Codex execution failed." >&2
    if [[ -f "$WORK_DIR/codex-stderr.log" ]]; then
      cat "$WORK_DIR/codex-stderr.log" >&2
    fi
    exit 3
  fi

  # Validate output
  if [[ ! -f "$WORK_DIR/codex-output.json" ]]; then
    echo "Error: Codex did not produce output." >&2
    exit 3
  fi

  if ! jq empty "$WORK_DIR/codex-output.json" 2>/dev/null; then
    echo "Error: Codex output is not valid JSON." >&2
    exit 3
  fi
}

# ─── Chunked Review Path ────────────────────────────────────────────────────
run_chunked_review() {
  local pr_number="$1"
  local pr_title="$2"
  local head_branch="$3"
  local base_branch="$4"
  local diff="$5"
  local project_rules="$6"

  # Copy schema to work dir
  cp "$SCRIPT_DIR/codex-output-schema.json" "$WORK_DIR/"

  # Write diff to file and split into chunks
  local diff_file="$WORK_DIR/full-diff.txt"
  echo "$diff" > "$diff_file"

  local chunk_dir="$WORK_DIR/chunks"
  mkdir -p "$chunk_dir"

  echo "Splitting diff into chunks (chunk size: $CHUNK_SIZE lines)..." >&2
  awk -v chunk_size="$CHUNK_SIZE" -v output_dir="$chunk_dir" \
    -f "$SCRIPT_DIR/chunk-diff.awk" < "$diff_file"

  local total_chunks
  total_chunks=$(cat "$chunk_dir/chunk_count.txt")
  echo "Split into $total_chunks chunks." >&2

  # If chunking produced only 1 chunk, fall back to single review
  if [[ "$total_chunks" -eq 1 ]]; then
    echo "Only 1 chunk produced, using single review path." >&2
    local single_diff
    single_diff=$(cat "$chunk_dir/chunk_001.diff")
    run_single_review "$pr_number" "$pr_title" "$head_branch" "$base_branch" "$single_diff" "$project_rules"
    return
  fi

  # Launch parallel chunk reviews
  echo "Launching $total_chunks parallel chunk reviews..." >&2
  local pids=()
  local chunk_outputs=()

  for i in $(seq 1 "$total_chunks"); do
    local padded
    padded=$(printf "%03d" "$i")
    local chunk_file="$chunk_dir/chunk_${padded}.diff"
    local output_file="$WORK_DIR/chunk-output-${padded}.json"
    chunk_outputs+=("$output_file")

    review_chunk "$chunk_file" "$i" "$total_chunks" \
      "$pr_number" "$pr_title" "$head_branch" "$base_branch" \
      "$project_rules" "$output_file" &
    pids+=($!)
  done

  # Wait for all chunks and count failures
  local failures=0
  local succeeded=0
  for i in "${!pids[@]}"; do
    if wait "${pids[$i]}"; then
      succeeded=$((succeeded + 1))
    else
      failures=$((failures + 1))
    fi
  done

  echo "Chunk reviews complete: $succeeded succeeded, $failures failed." >&2

  # If ALL chunks failed, exit
  if [[ "$succeeded" -eq 0 ]]; then
    echo "Error: All chunk reviews failed." >&2
    for i in $(seq 1 "$total_chunks"); do
      local padded
      padded=$(printf "%03d" "$i")
      local stderr_file="$WORK_DIR/chunk-stderr-${padded}.log"
      if [[ -f "$stderr_file" ]] && [[ -s "$stderr_file" ]]; then
        echo "--- Chunk $i stderr ---" >&2
        cat "$stderr_file" >&2
      fi
    done
    exit 3
  fi

  # Build chunk results JSON array from successful outputs
  echo "Synthesizing chunk results..." >&2
  local chunk_results="["
  local first=true

  for i in $(seq 1 "$total_chunks"); do
    local padded
    padded=$(printf "%03d" "$i")
    local output_file="$WORK_DIR/chunk-output-${padded}.json"

    if [[ -f "$output_file" ]] && jq empty "$output_file" 2>/dev/null; then
      if [[ "$first" == "true" ]]; then
        first=false
      else
        chunk_results+=","
      fi
      # Wrap each chunk result with its chunk number
      chunk_results+=$(jq -c --argjson n "$i" '{chunk: $n, result: .}' "$output_file")
    fi
  done

  chunk_results+="]"

  # Build and run synthesis prompt
  local synthesis_prompt
  synthesis_prompt=$(build_synthesis_prompt "$pr_number" "$pr_title" "$head_branch" "$base_branch" "$chunk_results" "$total_chunks")

  local synthesis_prompt_file="$WORK_DIR/synthesis-prompt.md"
  echo "$synthesis_prompt" > "$synthesis_prompt_file"

  echo "Running synthesis review..." >&2
  if ! codex exec \
    --model "$MODEL" \
    --output-schema "$WORK_DIR/codex-output-schema.json" \
    --sandbox read-only \
    - < "$synthesis_prompt_file" > "$WORK_DIR/codex-output.json" 2>"$WORK_DIR/synthesis-stderr.log"; then
    echo "Error: Synthesis step failed." >&2
    if [[ -f "$WORK_DIR/synthesis-stderr.log" ]]; then
      cat "$WORK_DIR/synthesis-stderr.log" >&2
    fi
    exit 3
  fi

  # Validate synthesis output
  if [[ ! -f "$WORK_DIR/codex-output.json" ]]; then
    echo "Error: Synthesis did not produce output." >&2
    exit 3
  fi

  if ! jq empty "$WORK_DIR/codex-output.json" 2>/dev/null; then
    echo "Error: Synthesis output is not valid JSON." >&2
    exit 3
  fi
}

# ─── Format Comment ──────────────────────────────────────────────────────────
format_comment() {
  local output_file="$1"
  local pr_url="$2"
  local total_findings filtered_count

  total_findings=$(jq '.findings | length' "$output_file")
  filtered_count=$(jq --arg t "$THRESHOLD" '[.findings[] | select(.confidence_score >= ($t | tonumber))] | length' "$output_file")

  local verdict confidence_score explanation
  verdict=$(jq -r '.overall_correctness' "$output_file")
  confidence_score=$(jq -r '.overall_confidence_score' "$output_file")
  explanation=$(jq -r '.overall_explanation' "$output_file")

  local verdict_emoji="✅"
  if [[ "$verdict" == "patch is incorrect" ]]; then
    verdict_emoji="❌"
  fi

  # Build comment
  local comment=""
  comment+="### Codex PR Review ($MODEL)"$'\n\n'
  comment+="**Verdict:** $verdict_emoji $verdict (confidence: $confidence_score)"$'\n\n'
  comment+="**Summary:** $explanation"$'\n\n'
  comment+="---"$'\n\n'

  if [[ "$filtered_count" -eq 0 ]]; then
    comment+="No findings above confidence threshold ($THRESHOLD)."$'\n\n'
  else
    comment+="#### Findings ($filtered_count above threshold $THRESHOLD)"$'\n\n'
    comment+="| # | Priority | Finding | Location | Confidence |"$'\n'
    comment+="|---|----------|---------|----------|------------|"$'\n'

    local idx=0
    while IFS= read -r finding; do
      idx=$((idx + 1))
      local title body priority path start_line end_line conf
      title=$(echo "$finding" | jq -r '.title')
      priority=$(echo "$finding" | jq -r '.priority')
      path=$(echo "$finding" | jq -r '.code_location.path')
      start_line=$(echo "$finding" | jq -r '.code_location.start_line')
      end_line=$(echo "$finding" | jq -r '.code_location.end_line')
      conf=$(echo "$finding" | jq -r '.confidence_score')

      local priority_label
      case "$priority" in
        3) priority_label="HIGH" ;;
        2) priority_label="MEDIUM" ;;
        1) priority_label="LOW" ;;
        *) priority_label="INFO" ;;
      esac

      local location="\`${path}:${start_line}"
      if [[ "$start_line" != "$end_line" ]]; then
        location+="-${end_line}"
      fi
      location+="\`"

      comment+="| $idx | $priority_label | $title | $location | $conf |"$'\n'
    done < <(jq -c --arg t "$THRESHOLD" '.findings[] | select(.confidence_score >= ($t | tonumber))' "$output_file" | jq -c '.' | sort -t: -k1 -rn 2>/dev/null || cat)

    comment+=$'\n'
    comment+="<details><summary>Detailed findings</summary>"$'\n\n'

    idx=0
    while IFS= read -r finding; do
      idx=$((idx + 1))
      local title body priority path start_line end_line conf
      title=$(echo "$finding" | jq -r '.title')
      body=$(echo "$finding" | jq -r '.body')
      priority=$(echo "$finding" | jq -r '.priority')
      path=$(echo "$finding" | jq -r '.code_location.path')
      start_line=$(echo "$finding" | jq -r '.code_location.start_line')
      end_line=$(echo "$finding" | jq -r '.code_location.end_line')
      conf=$(echo "$finding" | jq -r '.confidence_score')

      local priority_label
      case "$priority" in
        3) priority_label="HIGH" ;;
        2) priority_label="MEDIUM" ;;
        1) priority_label="LOW" ;;
        *) priority_label="INFO" ;;
      esac

      comment+="**$idx. $title** (priority: $priority_label, confidence: $conf)"$'\n'
      comment+="\`${path}:${start_line}-${end_line}\`"$'\n\n'
      comment+="> $body"$'\n\n'
      comment+="---"$'\n\n'
    done < <(jq -c --arg t "$THRESHOLD" '.findings[] | select(.confidence_score >= ($t | tonumber))' "$output_file")

    comment+="</details>"$'\n\n'
  fi

  comment+="---"$'\n'
  comment+="*Reviewed by OpenAI Codex ($MODEL) | Threshold: $THRESHOLD | $total_findings total findings, $filtered_count reported*"

  echo "$comment"
}

# ─── Main ─────────────────────────────────────────────────────────────────────
main() {
  check_prereqs

  echo "Detecting PR..." >&2
  local pr_json
  pr_json=$(detect_pr)

  local pr_number pr_title head_branch base_branch pr_url
  pr_number=$(echo "$pr_json" | jq -r '.number')
  pr_title=$(echo "$pr_json" | jq -r '.title')
  head_branch=$(echo "$pr_json" | jq -r '.headRefName')
  base_branch=$(echo "$pr_json" | jq -r '.baseRefName')
  pr_url=$(echo "$pr_json" | jq -r '.url')

  echo "Reviewing PR #$pr_number: $pr_title" >&2
  echo "  Branch: $head_branch → $base_branch" >&2
  echo "  Model: $MODEL | Threshold: $THRESHOLD | Chunk size: $CHUNK_SIZE" >&2

  # Gather diff
  echo "Gathering diff..." >&2
  local diff
  diff=$(gh pr diff "$pr_url")

  if [[ -z "$diff" ]]; then
    echo "Error: PR diff is empty." >&2
    exit 2
  fi

  # Safety valve: truncate truly enormous diffs
  local diff_lines
  diff_lines=$(echo "$diff" | wc -l | tr -d ' ')
  if [[ "$diff_lines" -gt "$MAX_DIFF_LINES" ]]; then
    echo "Warning: Diff is $diff_lines lines, truncating to $MAX_DIFF_LINES (safety limit)." >&2
    diff=$(echo "$diff" | head -n "$MAX_DIFF_LINES")
    diff+=$'\n\n... (diff truncated at '"$MAX_DIFF_LINES"' lines)'
    diff_lines="$MAX_DIFF_LINES"
  fi

  # Gather project rules
  echo "Checking for CLAUDE.md..." >&2
  local project_rules
  project_rules=$(gather_project_rules)

  # Route: single review vs chunked review
  if [[ "$diff_lines" -le "$CHUNK_SIZE" ]]; then
    echo "Diff is $diff_lines lines (within chunk size $CHUNK_SIZE), using single review." >&2
    run_single_review "$pr_number" "$pr_title" "$head_branch" "$base_branch" "$diff" "$project_rules"
  else
    echo "Diff is $diff_lines lines (exceeds chunk size $CHUNK_SIZE), using chunked review." >&2
    run_chunked_review "$pr_number" "$pr_title" "$head_branch" "$base_branch" "$diff" "$project_rules"
  fi

  # Format and post (same for both paths — both produce codex-output.json)
  echo "Formatting results..." >&2
  local comment
  comment=$(format_comment "$WORK_DIR/codex-output.json" "$pr_url")

  echo "Posting review to PR #$pr_number..." >&2
  if ! gh pr comment "$pr_url" --body "$comment" 2>"$WORK_DIR/gh-stderr.log"; then
    echo "Error: Failed to post PR comment." >&2
    if [[ -f "$WORK_DIR/gh-stderr.log" ]]; then
      cat "$WORK_DIR/gh-stderr.log" >&2
    fi
    # Still output the comment so the user can see it
    echo "--- Review output (not posted) ---"
    echo "$comment"
    exit 4
  fi

  # Output summary JSON for Claude to parse
  local filtered_count total_findings
  total_findings=$(jq '.findings | length' "$WORK_DIR/codex-output.json")
  filtered_count=$(jq --arg t "$THRESHOLD" '[.findings[] | select(.confidence_score >= ($t | tonumber))] | length' "$WORK_DIR/codex-output.json")

  jq -n \
    --arg pr_url "$pr_url" \
    --arg pr_number "$pr_number" \
    --arg verdict "$(jq -r '.overall_correctness' "$WORK_DIR/codex-output.json")" \
    --arg confidence "$(jq -r '.overall_confidence_score' "$WORK_DIR/codex-output.json")" \
    --arg explanation "$(jq -r '.overall_explanation' "$WORK_DIR/codex-output.json")" \
    --argjson total "$total_findings" \
    --argjson reported "$filtered_count" \
    --arg threshold "$THRESHOLD" \
    --arg model "$MODEL" \
    '{
      status: "success",
      pr_url: $pr_url,
      pr_number: $pr_number,
      model: $model,
      threshold: $threshold,
      verdict: $verdict,
      overall_confidence: $confidence,
      explanation: $explanation,
      total_findings: $total,
      reported_findings: $reported
    }'

  echo "Review posted to $pr_url" >&2
}

main
