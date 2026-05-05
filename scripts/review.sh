#!/usr/bin/env bash
set -euo pipefail

# ─── Codex PR Review ─────────────────────────────────────────────────────────
# Orchestrates a PR code review using OpenAI Codex CLI.
# Usage: review.sh [PR_NUMBER|PR_URL] [--threshold FLOAT] [--model MODEL]
#                  [--max-diff-lines INT] [--chunk-size INT] [--max-parallel INT]
#                  [--no-verify]
# ──────────────────────────────────────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK_DIR=$(mktemp -d)
FAILURE_DIR=""   # populated by preserve_chunk_failures when there are any

cleanup_work_dir() {
  preserve_chunk_failures
  rm -rf "$WORK_DIR"
  if [[ -n "$FAILURE_DIR" ]]; then
    echo "Chunk failure diagnostics saved to: $FAILURE_DIR" >&2
  fi
}

# Copy any chunk stderr logs whose chunk output is missing or invalid JSON into
# a persistent directory so the user can diagnose what went wrong.
# Note: stderr and prompt files use the raw (unpadded) chunk number; output JSON
# files use 3-digit zero-padded numbers. Bridge both when checking/copying.
preserve_chunk_failures() {
  [[ -d "$WORK_DIR" ]] || return 0
  local stderr_log num padded out_file prompt_file family raw_num

  # v1: chunk-stderr-N.log alongside chunk-output-NNN.json (one family).
  # v2 additive: chunk-stderr-codex-N.log / chunk-stderr-claude-N.log alongside
  # chunk-output-codex-NNN.json / chunk-output-claude-NNN.json.
  for stderr_log in "$WORK_DIR"/chunk-stderr-*.log; do
    [[ -f "$stderr_log" ]] || continue
    raw_num="${stderr_log##*chunk-stderr-}"
    raw_num="${raw_num%.log}"

    # Detect family-tagged form (codex-N / claude-N) vs. legacy (N).
    family=""
    num="$raw_num"
    case "$raw_num" in
      codex-*) family="codex"; num="${raw_num#codex-}" ;;
      claude-*) family="claude"; num="${raw_num#claude-}" ;;
    esac

    padded=$(printf "%03d" "$num" 2>/dev/null || echo "$num")

    if [[ -n "$family" ]]; then
      out_file="$WORK_DIR/chunk-output-${family}-${padded}.json"
      prompt_file="$WORK_DIR/chunk-prompt-${family}-${num}.md"
    else
      out_file="$WORK_DIR/chunk-output-${padded}.json"
      prompt_file="$WORK_DIR/chunk-prompt-${num}.md"
    fi

    if [[ ! -f "$out_file" ]] || ! jq empty "$out_file" 2>/dev/null; then
      if [[ -z "$FAILURE_DIR" ]]; then
        FAILURE_DIR="/tmp/codex-pr-review-failures-$(date -u +%Y%m%dT%H%M%SZ)-$$"
        mkdir -p "$FAILURE_DIR"
      fi
      local failure_prefix
      if [[ -n "$family" ]]; then
        failure_prefix="chunk-${family}-${padded}"
      else
        failure_prefix="chunk-${padded}"
      fi
      cp "$stderr_log" "$FAILURE_DIR/${failure_prefix}-stderr.log" 2>/dev/null || true
      [[ -f "$prompt_file" ]] && cp "$prompt_file" "$FAILURE_DIR/${failure_prefix}-prompt.md" 2>/dev/null || true
    fi
  done
}

trap cleanup_work_dir EXIT

# ─── V2 Work-dir Layout ───────────────────────────────────────────────────────
# Documented layout for this script's $WORK_DIR (additive across phases):
#
#   $WORK_DIR/
#     plan.json                        # output of scripts/plan.js (P1)
#     full-diff.txt                    # full PR diff (v1, unchanged)
#     manifest.md                      # legacy manifest (still consumed by prompts)
#     chunks/
#       chunk_001.diff  ...            # per-chunk diffs (v1 contract preserved)
#       chunk_count.txt                # number of chunks
#     chunk-prompt-codex-N.md          # P2: family-specific prompt files
#     chunk-prompt-claude-N.md
#     chunk-output-NNN.json            # v1 single-family output (kept for back-compat)
#     chunk-output-codex-NNN.json      # P2: per-family outputs
#     chunk-output-claude-NNN.json
#     chunk-stderr-N.log               # v1 stderr (kept)
#     chunk-stderr-codex-N.log         # P2: per-family stderr
#     chunk-stderr-claude-N.log
#     det-findings.json                # P3: deterministic floor output
#     verifier/
#       finding-<id>-verdict.json      # P2: per-finding verifier output (id = sha256[:8])
#       finding-<id>-stderr.log
#     merged-findings.json             # P2: post-verifier merged list
#     synthesis-prompt.md              # synthesis prompt (v1, unchanged)
#     codex-output.json                # final synthesis output (name preserved)
#     pr-comment.md                    # the body posted to gh pr comment
#
# Naming intent: per-chunk files use a 1-based padded number (chunk-output-NNN);
# per-prompt files use the unpadded chunk number (chunk-prompt-N). This mirrors
# the v1 convention so preserve_chunk_failures() can bridge both.

# ─── Defaults ─────────────────────────────────────────────────────────────────
THRESHOLD="0.8"
MODEL="gpt-5.3-codex"
MAX_DIFF_LINES="0"   # 0 = unlimited; chunking handles arbitrarily large diffs
CHUNK_SIZE="3000"
MAX_PARALLEL="6"     # concurrent codex exec calls during chunked review
VERIFY_ENABLED="true"
PR_ARG=""

# v2 additions (P1):
CHUNKER="auto"           # auto | ast | hunk
REVIEW_RULES_ARG=""      # path to override REVIEW.md / CLAUDE.md
MODEL_CODEX="gpt-5.3-codex"
MODEL_CLAUDE="claude-opus-4-7"  # accepted in P1 but non-functional until P2

# ─── Arg Parsing ──────────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --threshold)
      THRESHOLD="$2"
      shift 2
      ;;
    --model)
      # v1 alias: --model is equivalent to --model-codex.
      MODEL="$2"
      MODEL_CODEX="$2"
      shift 2
      ;;
    --model-codex)
      MODEL="$2"
      MODEL_CODEX="$2"
      shift 2
      ;;
    --model-claude)
      MODEL_CLAUDE="$2"
      shift 2
      ;;
    --chunker)
      case "$2" in
        auto|ast|hunk) CHUNKER="$2" ;;
        *) echo "Error: --chunker must be auto|ast|hunk, got: $2" >&2; exit 1 ;;
      esac
      shift 2
      ;;
    --review-rules)
      REVIEW_RULES_ARG="$2"
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
    --max-parallel)
      MAX_PARALLEL="$2"
      shift 2
      ;;
    --no-verify)
      VERIFY_ENABLED="false"
      shift
      ;;
    -h|--help)
      cat >&2 <<'USAGE'
Usage: review.sh [PR_NUMBER|PR_URL] [options]

Options:
  --threshold FLOAT      Confidence threshold (default 0.8)
  --model MODEL          Codex model (alias for --model-codex)
  --model-codex MODEL    Codex model (default gpt-5.3-codex)
  --model-claude MODEL   Claude model (default claude-opus-4-7; P2+)
  --chunker MODE         auto | ast | hunk (default auto)
  --review-rules PATH    Path to REVIEW.md override (must exist)
  --max-diff-lines N     Truncate diff at N lines (0 = unlimited)
  --chunk-size N         Lines per chunk (default 3000)
  --max-parallel N       Concurrent slots during chunked review (default 6)
  --no-verify            Skip the post-synthesis verification pass
  -h, --help             Show this help and exit
USAGE
      exit 0
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

# Hard-fail if --review-rules path was specified but does not exist.
if [[ -n "$REVIEW_RULES_ARG" && ! -f "$REVIEW_RULES_ARG" ]]; then
  echo "Error: --review-rules path does not exist: $REVIEW_RULES_ARG" >&2
  exit 1
fi

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

  # ─── V2 soft prereqs (warn-only at P0/P1; hard-fail will land with P2) ───
  if ! command -v claude &>/dev/null; then
    echo "Note: claude CLI not found on PATH. v2 dual-family review (P2+) will not work; v1 single-Codex flow is unaffected." >&2
  fi

  if command -v node &>/dev/null; then
    local node_major
    node_major=$(node --version 2>/dev/null | sed -E 's/^v([0-9]+).*/\1/' || echo "0")
    if [[ -z "$node_major" || "$node_major" -lt 18 ]]; then
      echo "Note: node version is below 18 (got: $(node --version 2>/dev/null || echo 'unknown')). v2 AST chunker (plan.js) requires Node >= 18; falling back to AWK chunker." >&2
    fi
  else
    echo "Note: node not found on PATH. v2 AST chunker (plan.js) will fall back to AWK chunker." >&2
  fi
}

# ─── PR Detection ─────────────────────────────────────────────────────────────
detect_pr() {
  local pr_json

  if [[ -n "$PR_ARG" ]]; then
    # Extract number from URL if needed
    local pr_num
    pr_num=$(echo "$PR_ARG" | grep -oE '[0-9]+$' || echo "$PR_ARG")
    pr_json=$(gh pr view "$pr_num" --json number,title,headRefName,baseRefName,url 2>/dev/null) || {
      echo "Error: Could not find PR #$pr_num" >&2
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

# ─── REVIEW.md / CLAUDE.md Discovery ─────────────────────────────────────────
# v2: prefer REVIEW.md; fall back to CLAUDE.md (v1 behavior). The --review-rules
# flag overrides discovery. The result is rendered under "## Review-only Rules"
# in the prompt and is a STRICT SUPERSET of v1's CLAUDE.md injection — v1 callers
# get identical content, v2 callers get REVIEW.md if present.
gather_project_rules() {
  local repo_root
  repo_root=$(git rev-parse --show-toplevel 2>/dev/null || echo ".")
  local rules=""
  local source_path=""

  if [[ -n "$REVIEW_RULES_ARG" ]]; then
    source_path="$REVIEW_RULES_ARG"
  elif [[ -f "$repo_root/REVIEW.md" ]]; then
    source_path="$repo_root/REVIEW.md"
  elif [[ -f "$repo_root/CLAUDE.md" ]]; then
    source_path="$repo_root/CLAUDE.md"
  fi

  if [[ -n "$source_path" && -f "$source_path" ]]; then
    rules+="The project has the following rules that must be respected (source: $(basename "$source_path")):"$'\n\n'
    rules+=$(cat "$source_path")
    rules+=$'\n\n'
  fi

  echo "$rules"
}

# ─── Prior Review Detection ─────────────────────────────────────────────────
gather_prior_review() {
  local pr_number="$1"
  local repo
  repo=$(gh repo view --json nameWithOwner -q '.nameWithOwner' 2>/dev/null) || return 1

  # Fetch all Codex review comment bodies (base64-encoded, one per line)
  local encoded_bodies
  encoded_bodies=$(gh api "repos/$repo/issues/$pr_number/comments" \
    --paginate \
    --jq '.[] | select(.body | contains("CODEX_REVIEW_DATA_START")) | .body | @base64' 2>/dev/null)

  if [[ -z "$encoded_bodies" ]]; then
    return 1
  fi

  # Take the last (most recent) and decode
  local last_encoded
  last_encoded=$(echo "$encoded_bodies" | tail -1)
  local comment_body
  comment_body=$(echo "$last_encoded" | jq -Rr '@base64d')

  if [[ -z "$comment_body" ]]; then
    return 1
  fi

  # Extract review JSON from between markers
  local review_data
  review_data=$(echo "$comment_body" | sed -n '/CODEX_REVIEW_DATA_START/,/CODEX_REVIEW_DATA_END/{//d;p;}')

  if [[ -n "$review_data" ]] && echo "$review_data" | jq empty 2>/dev/null; then
    echo "$review_data"
    return 0
  fi

  return 1
}

# ─── Build Manifest (v1 fallback) ───────────────────────────────────────────
build_manifest_v1() {
  local diff_file="$1"
  local out_file="$2"

  {
    echo "### Files changed in this PR"
    grep -E '^diff --git ' "$diff_file" \
      | sed -E 's|^diff --git a/([^ ]+) b/.*|- \1|' \
      | sort -u

    echo
    echo "### Symbols added in this PR"
    grep -E '^\+' "$diff_file" \
      | grep -vE '^\+\+\+ ' \
      | grep -oE '(def|class|function|const|let|var|fn|pub fn|type|interface|struct|enum|export (default )?(function|class|const|interface|type))[[:space:]]+[A-Za-z_][A-Za-z0-9_]*' \
      | sort -u \
      | head -200
  } > "$out_file"
}

# ─── Build Plan + Manifest (v2 P1) ──────────────────────────────────────────
# Invokes scripts/plan.js to produce $WORK_DIR/plan.json. On any failure (node
# missing, plan.js error, output unreadable), falls back to the v1 grep-based
# manifest with a stderr warning. This is purely additive: the legacy
# manifest.md path is preserved for the existing prompt injection seam.
build_plan_and_manifest() {
  local diff_file="$1"
  local manifest_file="$2"
  local plan_file="$WORK_DIR/plan.json"

  if ! command -v node &>/dev/null; then
    echo "Note: node not found; using v1 manifest builder." >&2
    build_manifest_v1 "$diff_file" "$manifest_file"
    return 0
  fi

  if [[ ! -f "$SCRIPT_DIR/plan.js" ]]; then
    echo "Note: plan.js not found; using v1 manifest builder." >&2
    build_manifest_v1 "$diff_file" "$manifest_file"
    return 0
  fi

  local chunker_arg="$CHUNKER"
  if [[ -z "$chunker_arg" ]]; then chunker_arg="auto"; fi

  if ! node "$SCRIPT_DIR/plan.js" \
        --diff "$diff_file" \
        --output "$plan_file" \
        --chunk-size "$CHUNK_SIZE" \
        --chunker "$chunker_arg" \
        --awk "$SCRIPT_DIR/chunk-diff.awk" \
        --chunks-dir "$WORK_DIR/chunks" \
        2>"$WORK_DIR/plan-stderr.log"; then
    echo "Warning: plan.js failed; falling back to v1 manifest builder." >&2
    if [[ -s "$WORK_DIR/plan-stderr.log" ]]; then
      sed -e 's/^/  /' "$WORK_DIR/plan-stderr.log" >&2 || true
    fi
    build_manifest_v1 "$diff_file" "$manifest_file"
    return 0
  fi

  # Surface any plan.js stderr warnings (e.g., tree-sitter unavailable) to the
  # user even on success.
  if [[ -s "$WORK_DIR/plan-stderr.log" ]]; then
    sed -e 's/^/  /' "$WORK_DIR/plan-stderr.log" >&2 || true
  fi

  # Extract manifest_text from plan.json into the legacy manifest.md path.
  if ! jq -r '.manifest_text // ""' "$plan_file" > "$manifest_file" 2>/dev/null; then
    echo "Warning: could not extract manifest_text from plan.json; using v1." >&2
    build_manifest_v1 "$diff_file" "$manifest_file"
  fi
}

# Read per-chunk neighbors from plan.json. Outputs a markdown bullet list to
# stdout (or "_No cross-chunk neighbors detected._" when the list is empty or
# plan.json is unavailable).
read_plan_neighbors() {
  local chunk_id="$1"
  local plan_file="$WORK_DIR/plan.json"
  if [[ ! -f "$plan_file" ]]; then
    echo "_No cross-chunk neighbors detected._"
    return 0
  fi
  local n_count
  n_count=$(jq --argjson cid "$chunk_id" '[.chunks[] | select(.id == $cid) | .neighbors[]?] | length' "$plan_file" 2>/dev/null || echo 0)
  if [[ -z "$n_count" || "$n_count" == "0" || "$n_count" == "null" ]]; then
    echo "_No cross-chunk neighbors detected._"
    return 0
  fi
  jq -r --argjson cid "$chunk_id" '
    .chunks[] | select(.id == $cid) | .neighbors[] |
    "- `" + .symbol + "` — defined in chunk " + (.defined_in_chunk|tostring) + " (`" + .file + "`)"
  ' "$plan_file" 2>/dev/null
}

# ─── Build Follow-up Context ────────────────────────────────────────────────
build_followup_context() {
  local prior_review_json="$1"
  local review_iteration="$2"

  local template
  template=$(cat "$SCRIPT_DIR/codex-followup-context.md")

  local prior_verdict prior_confidence prior_explanation prior_findings
  prior_verdict=$(echo "$prior_review_json" | jq -r '.output.overall_correctness')
  prior_confidence=$(echo "$prior_review_json" | jq -r '.output.overall_confidence_score')
  prior_explanation=$(echo "$prior_review_json" | jq -r '.output.overall_explanation')
  prior_findings=$(echo "$prior_review_json" | jq -c '.output.findings')

  template="${template//\{\{REVIEW_ITERATION\}\}/$review_iteration}"
  template="${template//\{\{PRIOR_VERDICT\}\}/$prior_verdict}"
  template="${template//\{\{PRIOR_CONFIDENCE\}\}/$prior_confidence}"
  template="${template//\{\{PRIOR_EXPLANATION\}\}/$prior_explanation}"
  template="${template//\{\{PRIOR_FINDINGS\}\}/$prior_findings}"

  echo "$template"
}

# ─── Build Prompt (file-based to avoid bash O(n*m) substitution on large diffs)
build_prompt() {
  local pr_number="$1"
  local pr_title="$2"
  local head_branch="$3"
  local base_branch="$4"
  local diff_file="$5"   # path to diff file (NOT inline content)
  local project_rules="$6"
  local followup_context="$7"
  local manifest_file="$8"  # path to manifest file
  local output_file="$9"  # path to write filled prompt

  # v2: project_rules is rendered under {{REVIEW_RULES}} (REVIEW.md / CLAUDE.md
  # content). {{PROJECT_RULES}} is kept empty for back-compat with the prompt
  # template structure.
  local review_rules_section="$project_rules"
  local project_rules_section=""

  local manifest_content=""
  if [[ -n "$manifest_file" && -f "$manifest_file" ]]; then
    manifest_content=$(cat "$manifest_file")
  fi

  # Single-review path has no chunks → no neighbors.
  local neighbors_content="_No cross-chunk neighbors (single-review path)._"

  # Use sed for small single-line placeholders (BSD sed can't handle newlines
  # in replacement text, so multi-line values go through perl below).
  LC_ALL=C sed \
    -e "s|{{PR_NUMBER}}|${pr_number}|g" \
    -e "s|{{PR_TITLE}}|${pr_title}|g" \
    -e "s|{{HEAD_BRANCH}}|${head_branch}|g" \
    -e "s|{{BASE_BRANCH}}|${base_branch}|g" \
    "$SCRIPT_DIR/codex-prompt.md" > "$WORK_DIR/_prompt_template_pre.md"

  PROJECT_RULES_VAL="$project_rules_section" \
  PRIOR_REVIEW_VAL="$followup_context" \
  MANIFEST_VAL="$manifest_content" \
  REVIEW_RULES_VAL="$review_rules_section" \
  NEIGHBORS_VAL="$neighbors_content" \
  perl -pe '
    BEGIN {
      $pr  = $ENV{PROJECT_RULES_VAL};
      $prv = $ENV{PRIOR_REVIEW_VAL};
      $mf  = $ENV{MANIFEST_VAL};
      $rr  = $ENV{REVIEW_RULES_VAL};
      $nb  = $ENV{NEIGHBORS_VAL};
    }
    s/\Q{{PROJECT_RULES}}\E/$pr/g;
    s/\Q{{PRIOR_REVIEW}}\E/$prv/g;
    s/\Q{{MANIFEST}}\E/$mf/g;
    s/\Q{{REVIEW_RULES}}\E/$rr/g;
    s/\Q{{NEIGHBORS}}\E/$nb/g;
  ' "$WORK_DIR/_prompt_template_pre.md" > "$WORK_DIR/_prompt_template.md"

  # Split on {{DIFF}} line and splice diff file in between
  local line_num
  line_num=$(grep -n '{{DIFF}}' "$WORK_DIR/_prompt_template.md" | head -1 | cut -d: -f1)
  if [[ -n "$line_num" ]]; then
    head -n "$((line_num - 1))" "$WORK_DIR/_prompt_template.md" > "$output_file"
    cat "$diff_file" >> "$output_file"
    tail -n "+$((line_num + 1))" "$WORK_DIR/_prompt_template.md" >> "$output_file"
  else
    # No {{DIFF}} marker — just use template as-is
    cp "$WORK_DIR/_prompt_template.md" "$output_file"
  fi
}

# ─── Build Chunk Prompt (file-based) ────────────────────────────────────────
build_chunk_prompt() {
  local pr_number="$1"
  local pr_title="$2"
  local head_branch="$3"
  local base_branch="$4"
  local diff_file="$5"   # path to chunk diff file
  local project_rules="$6"
  local chunk_num="$7"
  local total_chunks="$8"
  local followup_context="$9"
  local manifest_file="${10}"  # path to manifest file
  local output_file="${11}"  # path to write filled prompt

  # v2: project_rules → {{REVIEW_RULES}}; {{PROJECT_RULES}} kept empty.
  local review_rules_section="$project_rules"
  local project_rules_section=""

  local manifest_content=""
  if [[ -n "$manifest_file" && -f "$manifest_file" ]]; then
    manifest_content=$(cat "$manifest_file")
  fi

  # Per-chunk neighbors block from plan.json (v2).
  local neighbors_content
  neighbors_content=$(read_plan_neighbors "$chunk_num")
  if [[ -z "$neighbors_content" ]]; then
    neighbors_content="_No cross-chunk neighbors detected._"
  fi

  # BSD sed can't handle newlines in replacement text, so multi-line values
  # go through perl below.
  LC_ALL=C sed \
    -e "s|{{PR_NUMBER}}|${pr_number}|g" \
    -e "s|{{PR_TITLE}}|${pr_title}|g" \
    -e "s|{{HEAD_BRANCH}}|${head_branch}|g" \
    -e "s|{{BASE_BRANCH}}|${base_branch}|g" \
    -e "s|{{CHUNK_NUM}}|${chunk_num}|g" \
    -e "s|{{TOTAL_CHUNKS}}|${total_chunks}|g" \
    "$SCRIPT_DIR/codex-chunk-prompt.md" > "$WORK_DIR/_chunk_template_pre_${chunk_num}.md"

  PROJECT_RULES_VAL="$project_rules_section" \
  PRIOR_REVIEW_VAL="$followup_context" \
  MANIFEST_VAL="$manifest_content" \
  REVIEW_RULES_VAL="$review_rules_section" \
  NEIGHBORS_VAL="$neighbors_content" \
  perl -pe '
    BEGIN {
      $pr  = $ENV{PROJECT_RULES_VAL};
      $prv = $ENV{PRIOR_REVIEW_VAL};
      $mf  = $ENV{MANIFEST_VAL};
      $rr  = $ENV{REVIEW_RULES_VAL};
      $nb  = $ENV{NEIGHBORS_VAL};
    }
    s/\Q{{PROJECT_RULES}}\E/$pr/g;
    s/\Q{{PRIOR_REVIEW}}\E/$prv/g;
    s/\Q{{MANIFEST}}\E/$mf/g;
    s/\Q{{REVIEW_RULES}}\E/$rr/g;
    s/\Q{{NEIGHBORS}}\E/$nb/g;
  ' "$WORK_DIR/_chunk_template_pre_${chunk_num}.md" > "$WORK_DIR/_chunk_template_${chunk_num}.md"

  local line_num
  line_num=$(grep -n '{{DIFF}}' "$WORK_DIR/_chunk_template_${chunk_num}.md" | head -1 | cut -d: -f1)
  if [[ -n "$line_num" ]]; then
    head -n "$((line_num - 1))" "$WORK_DIR/_chunk_template_${chunk_num}.md" > "$output_file"
    cat "$diff_file" >> "$output_file"
    tail -n "+$((line_num + 1))" "$WORK_DIR/_chunk_template_${chunk_num}.md" >> "$output_file"
  else
    cp "$WORK_DIR/_chunk_template_${chunk_num}.md" "$output_file"
  fi
}

# ─── Build Synthesis Prompt (file-based) ────────────────────────────────────
build_synthesis_prompt() {
  local pr_number="$1"
  local pr_title="$2"
  local head_branch="$3"
  local base_branch="$4"
  local chunk_results_file="$5"  # path to chunk results file
  local total_chunks="$6"
  local followup_context="$7"
  local diff_file="$8"  # path to full raw diff file
  local output_file="$9"  # path to write filled prompt

  LC_ALL=C sed \
    -e "s|{{PRIOR_REVIEW}}|${followup_context}|g" \
    -e "s|{{PR_NUMBER}}|${pr_number}|g" \
    -e "s|{{PR_TITLE}}|${pr_title}|g" \
    -e "s|{{HEAD_BRANCH}}|${head_branch}|g" \
    -e "s|{{BASE_BRANCH}}|${base_branch}|g" \
    -e "s|{{TOTAL_CHUNKS}}|${total_chunks}|g" \
    "$SCRIPT_DIR/codex-synthesis-prompt.md" > "$WORK_DIR/_synthesis_template.md"

  # Splice chunk results at {{CHUNK_RESULTS}}
  local line_num
  line_num=$(grep -n '{{CHUNK_RESULTS}}' "$WORK_DIR/_synthesis_template.md" | head -1 | cut -d: -f1)
  if [[ -n "$line_num" ]]; then
    head -n "$((line_num - 1))" "$WORK_DIR/_synthesis_template.md" > "$WORK_DIR/_synthesis_pre_diff.md"
    cat "$chunk_results_file" >> "$WORK_DIR/_synthesis_pre_diff.md"
    tail -n "+$((line_num + 1))" "$WORK_DIR/_synthesis_template.md" >> "$WORK_DIR/_synthesis_pre_diff.md"
  else
    cp "$WORK_DIR/_synthesis_template.md" "$WORK_DIR/_synthesis_pre_diff.md"
  fi

  # Decide whether to inline the raw diff or substitute a pointer sentence.
  # If the user set --max-diff-lines, use half that as the cap. Otherwise use
  # a sensible absolute cap so the synthesis prompt stays within context.
  local diff_threshold
  if [[ "$MAX_DIFF_LINES" -gt 0 ]]; then
    diff_threshold=$((MAX_DIFF_LINES / 2))
  else
    diff_threshold=30000
  fi
  local diff_lines=0
  if [[ -n "$diff_file" && -f "$diff_file" ]]; then
    diff_lines=$(wc -l < "$diff_file" | tr -d ' ')
  fi

  local diff_line_num
  diff_line_num=$(grep -n '{{DIFF}}' "$WORK_DIR/_synthesis_pre_diff.md" | head -1 | cut -d: -f1)
  if [[ -z "$diff_line_num" ]]; then
    # No {{DIFF}} marker — just use as-is
    cp "$WORK_DIR/_synthesis_pre_diff.md" "$output_file"
    return
  fi

  if [[ -n "$diff_file" && -f "$diff_file" && "$diff_lines" -le "$diff_threshold" ]]; then
    # Inline raw diff
    head -n "$((diff_line_num - 1))" "$WORK_DIR/_synthesis_pre_diff.md" > "$output_file"
    cat "$diff_file" >> "$output_file"
    tail -n "+$((diff_line_num + 1))" "$WORK_DIR/_synthesis_pre_diff.md" >> "$output_file"
  else
    # Substitute pointer sentence
    head -n "$((diff_line_num - 1))" "$WORK_DIR/_synthesis_pre_diff.md" > "$output_file"
    printf '%s\n' "The raw diff exceeds the synthesis budget. Rely on chunk outputs and use sandbox access if you need to verify specific files." >> "$output_file"
    tail -n "+$((diff_line_num + 1))" "$WORK_DIR/_synthesis_pre_diff.md" >> "$output_file"
  fi
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
  local followup_context="${10}"
  local manifest_file="${11}"

  local prompt_file="$WORK_DIR/chunk-prompt-${chunk_num}.md"
  build_chunk_prompt "$pr_number" "$pr_title" "$head_branch" "$base_branch" \
    "$chunk_file" "$project_rules" "$chunk_num" "$total_chunks" "$followup_context" "$manifest_file" "$prompt_file"

  local max_attempts=3
  local attempt=0
  # Per-attempt backoff (index 0 unused; 1→2s, 2→5s before retry).
  local backoffs=(0 2 5)
  while [[ $attempt -lt $max_attempts ]]; do
    attempt=$((attempt + 1))
    if codex exec \
      --model "$MODEL" \
      --output-schema "$WORK_DIR/codex-output-schema.json" \
      --sandbox read-only \
      - < "$prompt_file" > "$output_file" 2>"$WORK_DIR/chunk-stderr-${chunk_num}.log"; then
      if jq empty "$output_file" 2>/dev/null; then
        echo "  Chunk $chunk_num/$total_chunks completed$([ $attempt -gt 1 ] && echo " (retry $((attempt-1)))")." >&2
        return 0
      fi
    fi
    if [[ $attempt -lt $max_attempts ]]; then
      sleep "${backoffs[$attempt]}"
    fi
  done

  echo "  Chunk $chunk_num/$total_chunks FAILED after $max_attempts attempts." >&2
  return 1
}

# ─── Single Review Path ──────────────────────────────────────────────────────
run_single_review() {
  local pr_number="$1"
  local pr_title="$2"
  local head_branch="$3"
  local base_branch="$4"
  local diff_file="$5"   # path to diff file
  local project_rules="$6"
  local followup_context="$7"
  local manifest_file="$8"

  # Build prompt
  echo "Building review prompt..." >&2
  build_prompt "$pr_number" "$pr_title" "$head_branch" "$base_branch" \
    "$diff_file" "$project_rules" "$followup_context" "$manifest_file" "$WORK_DIR/codex-prompt-filled.md"

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
  local diff_file="$5"   # path to diff file
  local project_rules="$6"
  local followup_context="$7"
  local manifest_file="$8"

  # Copy schema to work dir
  cp "$SCRIPT_DIR/codex-output-schema.json" "$WORK_DIR/"

  local chunk_dir="$WORK_DIR/chunks"
  mkdir -p "$chunk_dir"

  echo "Splitting diff into chunks (chunk size: $CHUNK_SIZE lines, mode: $CHUNKER)..." >&2

  # v2 routing: plan.js (invoked from build_plan_and_manifest in main) may have
  # already written chunk files into $chunk_dir. If so, accept them. Otherwise,
  # decide between ast-chunk.sh and the legacy awk chunker.
  local used_ast=0

  if [[ -f "$chunk_dir/chunk_count.txt" ]] && \
     compgen -G "$chunk_dir/chunk_*.diff" >/dev/null; then
    # plan.js already produced chunks during manifest build.
    used_ast=1
  else
    local has_supported_lang=0
    if grep -qE '^diff --git a/.*\.(py|ts|tsx|go) ' "$diff_file"; then
      has_supported_lang=1
    fi

    local should_try_ast=0
    case "$CHUNKER" in
      ast)  should_try_ast=1 ;;
      auto) [[ "$has_supported_lang" -eq 1 ]] && should_try_ast=1 ;;
      hunk) should_try_ast=0 ;;
    esac

    if [[ "$should_try_ast" -eq 1 && -x "$SCRIPT_DIR/ast-chunk.sh" ]]; then
      if PLAN_JSON_OUT="$WORK_DIR/plan.json" AST_CHUNKER="$CHUNKER" \
          bash "$SCRIPT_DIR/ast-chunk.sh" "$CHUNK_SIZE" "$chunk_dir" \
          < "$diff_file" 2>"$WORK_DIR/ast-chunk-stderr.log"; then
        used_ast=1
        [[ -s "$WORK_DIR/ast-chunk-stderr.log" ]] && \
          sed -e 's/^/  /' "$WORK_DIR/ast-chunk-stderr.log" >&2 || true
      else
        echo "Note: ast-chunk.sh failed; falling back to AWK chunker." >&2
        [[ -s "$WORK_DIR/ast-chunk-stderr.log" ]] && \
          sed -e 's/^/  /' "$WORK_DIR/ast-chunk-stderr.log" >&2 || true
      fi
    fi

    if [[ "$used_ast" -ne 1 ]]; then
      LC_ALL=C awk -v chunk_size="$CHUNK_SIZE" -v output_dir="$chunk_dir" \
        -f "$SCRIPT_DIR/chunk-diff.awk" < "$diff_file"
    fi
  fi

  local total_chunks
  total_chunks=$(cat "$chunk_dir/chunk_count.txt")
  echo "Split into $total_chunks chunks (mode: $([ "$used_ast" -eq 1 ] && echo ast || echo hunk))." >&2

  # If chunking produced only 1 chunk, fall back to single review
  if [[ "$total_chunks" -eq 1 ]]; then
    echo "Only 1 chunk produced, using single review path." >&2
    run_single_review "$pr_number" "$pr_title" "$head_branch" "$base_branch" "$chunk_dir/chunk_001.diff" "$project_rules" "$followup_context" "$manifest_file"
    return
  fi

  # Launch chunk reviews in batches of MAX_PARALLEL to avoid overwhelming the
  # codex CLI and OpenAI rate limits.
  echo "Launching chunk reviews ($total_chunks total, max $MAX_PARALLEL concurrent)..." >&2
  local batch_pids=()

  for i in $(seq 1 "$total_chunks"); do
    local padded
    padded=$(printf "%03d" "$i")
    local chunk_file="$chunk_dir/chunk_${padded}.diff"
    local output_file="$WORK_DIR/chunk-output-${padded}.json"

    review_chunk "$chunk_file" "$i" "$total_chunks" \
      "$pr_number" "$pr_title" "$head_branch" "$base_branch" \
      "$project_rules" "$output_file" "$followup_context" "$manifest_file" &
    batch_pids+=($!)

    # If batch is full, drain before launching more.
    if [[ ${#batch_pids[@]} -ge $MAX_PARALLEL ]]; then
      for p in "${batch_pids[@]}"; do
        wait "$p" || true
      done
      batch_pids=()
    fi
  done

  # Drain the final partial batch.
  for p in "${batch_pids[@]}"; do
    wait "$p" || true
  done

  # Count successes/failures by inspecting output files (authoritative since
  # review_chunk writes valid JSON only on success).
  local failures=0
  local succeeded=0
  for i in $(seq 1 "$total_chunks"); do
    local padded
    padded=$(printf "%03d" "$i")
    local output_file="$WORK_DIR/chunk-output-${padded}.json"
    if [[ -f "$output_file" ]] && jq empty "$output_file" 2>/dev/null; then
      succeeded=$((succeeded + 1))
    else
      failures=$((failures + 1))
    fi
  done

  echo "Chunk reviews complete: $succeeded succeeded, $failures failed." >&2

  # Persist chunk stats so format_comment can warn about incomplete coverage.
  printf '%s\n%s\n' "$succeeded" "$failures" > "$WORK_DIR/chunk-stats.txt"

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

  # Build chunk results JSON array from successful outputs (write to file)
  echo "Synthesizing chunk results..." >&2
  local chunk_results_file="$WORK_DIR/chunk-results.json"
  printf "[" > "$chunk_results_file"
  local first=true

  for i in $(seq 1 "$total_chunks"); do
    local padded
    padded=$(printf "%03d" "$i")
    local output_file="$WORK_DIR/chunk-output-${padded}.json"

    if [[ -f "$output_file" ]] && jq empty "$output_file" 2>/dev/null; then
      if [[ "$first" == "true" ]]; then
        first=false
      else
        printf "," >> "$chunk_results_file"
      fi
      jq -c --argjson n "$i" '{chunk: $n, result: .}' "$output_file" >> "$chunk_results_file"
    fi
  done

  printf "]" >> "$chunk_results_file"

  # Build and run synthesis prompt
  local synthesis_prompt_file="$WORK_DIR/synthesis-prompt.md"
  build_synthesis_prompt "$pr_number" "$pr_title" "$head_branch" "$base_branch" \
    "$chunk_results_file" "$total_chunks" "$followup_context" "$diff_file" "$synthesis_prompt_file"

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

  # Optional verification pass (chunked path only). Non-blocking.
  if [[ "$VERIFY_ENABLED" == "true" ]]; then
    run_verification_pass "$WORK_DIR/codex-output.json" "$diff_file" \
      || echo "Warning: verification pass failed; using unverified output." >&2
  fi
}

# ─── Verification Pass ──────────────────────────────────────────────────────
run_verification_pass() {
  local output_file="$1"   # current codex-output.json (will be overwritten on success)
  local diff_file="$2"     # raw diff

  if [[ ! -f "$output_file" ]] || ! jq empty "$output_file" 2>/dev/null; then
    echo "Warning: verification pass skipped; output JSON missing or invalid." >&2
    return 1
  fi

  # Extract just the findings array for the prompt
  local findings_file="$WORK_DIR/verification-findings.json"
  if ! jq -c '.findings // []' "$output_file" > "$findings_file" 2>/dev/null; then
    echo "Warning: verification pass skipped; could not extract findings." >&2
    return 1
  fi

  # Build verification prompt
  local verification_prompt_file="$WORK_DIR/verification-prompt.md"
  cp "$SCRIPT_DIR/codex-verification-prompt.md" "$WORK_DIR/_verification_template.md"

  # Splice {{DIFF}}
  local diff_line_num
  diff_line_num=$(grep -n '{{DIFF}}' "$WORK_DIR/_verification_template.md" | head -1 | cut -d: -f1)
  if [[ -n "$diff_line_num" ]]; then
    head -n "$((diff_line_num - 1))" "$WORK_DIR/_verification_template.md" > "$WORK_DIR/_verification_post_diff.md"
    cat "$diff_file" >> "$WORK_DIR/_verification_post_diff.md"
    tail -n "+$((diff_line_num + 1))" "$WORK_DIR/_verification_template.md" >> "$WORK_DIR/_verification_post_diff.md"
  else
    cp "$WORK_DIR/_verification_template.md" "$WORK_DIR/_verification_post_diff.md"
  fi

  # Splice {{FINDINGS}}
  local findings_line_num
  findings_line_num=$(grep -n '{{FINDINGS}}' "$WORK_DIR/_verification_post_diff.md" | head -1 | cut -d: -f1)
  if [[ -n "$findings_line_num" ]]; then
    head -n "$((findings_line_num - 1))" "$WORK_DIR/_verification_post_diff.md" > "$verification_prompt_file"
    cat "$findings_file" >> "$verification_prompt_file"
    tail -n "+$((findings_line_num + 1))" "$WORK_DIR/_verification_post_diff.md" >> "$verification_prompt_file"
  else
    cp "$WORK_DIR/_verification_post_diff.md" "$verification_prompt_file"
  fi

  # Run codex verification (non-blocking — failures must not fail the review)
  local verified_out="$WORK_DIR/codex-output-verified.json"
  echo "Running verification pass..." >&2
  if ! codex exec \
    --model "$MODEL" \
    --output-schema "$WORK_DIR/codex-output-schema.json" \
    --sandbox read-only \
    - < "$verification_prompt_file" > "$verified_out" 2>"$WORK_DIR/verification-stderr.log"; then
    echo "Warning: verification codex exec failed; keeping unverified output." >&2
    if [[ -f "$WORK_DIR/verification-stderr.log" ]]; then
      cat "$WORK_DIR/verification-stderr.log" >&2
    fi
    return 1
  fi

  # Validate verified output
  if [[ ! -s "$verified_out" ]] || ! jq empty "$verified_out" 2>/dev/null; then
    echo "Warning: verification output invalid JSON; keeping unverified output." >&2
    return 1
  fi

  # Overwrite the original output with the verified version
  mv "$verified_out" "$output_file"
  echo "Verification pass complete." >&2
  return 0
}

# ─── Format Comment ──────────────────────────────────────────────────────────
format_comment() {
  local output_file="$1"
  local pr_url="$2"
  local review_iteration="$3"
  local head_sha="$4"
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

  # Build comment header
  local comment=""
  if [[ "$review_iteration" -gt 1 ]]; then
    comment+="### Codex PR Review ($MODEL) — Follow-up #$review_iteration"$'\n\n'
  else
    comment+="### Codex PR Review ($MODEL)"$'\n\n'
  fi
  comment+="**Verdict:** $verdict_emoji $verdict (confidence: $confidence_score)"$'\n\n'
  comment+="**Summary:** $explanation"$'\n\n'
  comment+="---"$'\n\n'

  # Show resolved prior findings for follow-up reviews
  if [[ "$review_iteration" -gt 1 ]]; then
    local resolved_count
    resolved_count=$(jq '[.resolved_prior_findings // [] | length] | .[0]' "$output_file")
    if [[ "$resolved_count" -gt 0 ]]; then
      comment+="#### Resolved from Prior Review"$'\n\n'
      while IFS= read -r resolved_title; do
        comment+="- ~~${resolved_title}~~"$'\n'
      done < <(jq -r '.resolved_prior_findings[]' "$output_file")
      comment+=$'\n'
    fi
  fi

  if [[ "$filtered_count" -eq 0 ]]; then
    comment+="No findings above confidence threshold ($THRESHOLD)."$'\n\n'
  else
    comment+="#### Findings ($filtered_count above threshold $THRESHOLD)"$'\n\n'
    comment+="| # | Priority | Finding | Location | Confidence |"$'\n'
    comment+="|---|----------|---------|----------|------------|"$'\n'

    local idx=0
    while IFS= read -r finding; do
      idx=$((idx + 1))
      local title priority path start_line end_line conf status
      title=$(echo "$finding" | jq -r '.title')
      priority=$(echo "$finding" | jq -r '.priority')
      path=$(echo "$finding" | jq -r '.code_location.path')
      start_line=$(echo "$finding" | jq -r '.code_location.start_line')
      end_line=$(echo "$finding" | jq -r '.code_location.end_line')
      conf=$(echo "$finding" | jq -r '.confidence_score')
      status=$(echo "$finding" | jq -r '.status // "new"')

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

      # Show status prefix for follow-up reviews
      local display_title="$title"
      if [[ "$review_iteration" -gt 1 && "$status" == "persisting" ]]; then
        display_title="[PERSISTING] $title"
      fi

      comment+="| $idx | $priority_label | $display_title | $location | $conf |"$'\n'
    done < <(jq -c --arg t "$THRESHOLD" '.findings[] | select(.confidence_score >= ($t | tonumber))' "$output_file" | jq -c '.' | sort -t: -k1 -rn 2>/dev/null || cat)

    comment+=$'\n'
    comment+="<details><summary>Detailed findings</summary>"$'\n\n'

    idx=0
    while IFS= read -r finding; do
      idx=$((idx + 1))
      local title body priority path start_line end_line conf status
      title=$(echo "$finding" | jq -r '.title')
      body=$(echo "$finding" | jq -r '.body')
      priority=$(echo "$finding" | jq -r '.priority')
      path=$(echo "$finding" | jq -r '.code_location.path')
      start_line=$(echo "$finding" | jq -r '.code_location.start_line')
      end_line=$(echo "$finding" | jq -r '.code_location.end_line')
      conf=$(echo "$finding" | jq -r '.confidence_score')
      status=$(echo "$finding" | jq -r '.status // "new"')

      local priority_label
      case "$priority" in
        3) priority_label="HIGH" ;;
        2) priority_label="MEDIUM" ;;
        1) priority_label="LOW" ;;
        *) priority_label="INFO" ;;
      esac

      local status_label=""
      if [[ "$review_iteration" -gt 1 && "$status" == "persisting" ]]; then
        status_label=" [PERSISTING]"
      fi

      comment+="**$idx. $title**${status_label} (priority: $priority_label, confidence: $conf)"$'\n'
      comment+="\`${path}:${start_line}-${end_line}\`"$'\n\n'
      comment+="> $body"$'\n\n'
      comment+="---"$'\n\n'
    done < <(jq -c --arg t "$THRESHOLD" '.findings[] | select(.confidence_score >= ($t | tonumber))' "$output_file")

    comment+="</details>"$'\n\n'
  fi

  # Footer
  local iteration_label=""
  if [[ "$review_iteration" -gt 1 ]]; then
    iteration_label=" | Follow-up #$review_iteration"
  fi
  comment+="---"$'\n'

  # Warn about incomplete coverage if any chunks failed during chunked review.
  if [[ -f "$WORK_DIR/chunk-stats.txt" ]]; then
    local stats_succeeded stats_failed
    stats_succeeded=$(sed -n '1p' "$WORK_DIR/chunk-stats.txt")
    stats_failed=$(sed -n '2p' "$WORK_DIR/chunk-stats.txt")
    if [[ "$stats_failed" -gt 0 ]]; then
      local total_c=$((stats_succeeded + stats_failed))
      comment+="> ⚠️ **Incomplete coverage:** ${stats_failed} of ${total_c} chunks failed during review. Findings below reflect only the ${stats_succeeded} successful chunks. Consider retrying or reducing \`--max-parallel\`."$'\n\n'
    fi
  fi

  comment+="*Reviewed by OpenAI Codex ($MODEL)${iteration_label} | Threshold: $THRESHOLD | $total_findings total findings, $filtered_count reported*"

  # Embed review data for future follow-up reviews
  local embed_json
  embed_json=$(jq -c \
    --argjson iteration "$review_iteration" \
    --arg sha "$head_sha" \
    --arg model "$MODEL" \
    --arg threshold "$THRESHOLD" \
    --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '{review_iteration: $iteration, head_sha: $sha, model: $model, threshold: ($threshold | tonumber), timestamp: $ts, output: .}' \
    "$output_file")

  comment+=$'\n\n'"<!-- CODEX_REVIEW_DATA_START"$'\n'
  comment+="$embed_json"$'\n'
  comment+="CODEX_REVIEW_DATA_END -->"

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

  # Check for prior Codex reviews
  echo "Checking for prior Codex reviews..." >&2
  local prior_review_json="" review_iteration=1 followup_context=""
  if prior_review_json=$(gather_prior_review "$pr_number"); then
    local prior_iteration
    prior_iteration=$(echo "$prior_review_json" | jq -r '.review_iteration // 1')
    review_iteration=$((prior_iteration + 1))
    echo "  Found prior review (iteration $prior_iteration). This will be follow-up review #$review_iteration." >&2
    followup_context=$(build_followup_context "$prior_review_json" "$review_iteration")
  else
    echo "  No prior Codex reviews found. This will be the initial review." >&2
  fi

  # Get current HEAD SHA for embedding
  local head_sha
  head_sha=$(git rev-parse HEAD 2>/dev/null || echo "unknown")

  # Gather diff — write directly to file to avoid storing huge diffs in bash variables
  echo "Gathering diff..." >&2
  local diff_file="$WORK_DIR/full-diff.txt"
  gh pr diff "$pr_number" > "$diff_file" 2>/dev/null || true

  if [[ ! -s "$diff_file" ]]; then
    echo "  gh pr diff failed (diff may be too large for GitHub API). Falling back to git diff..." >&2
    git fetch origin "$base_branch" "$head_branch" 2>/dev/null || true
    git diff "origin/${base_branch}...origin/${head_branch}" > "$diff_file" 2>/dev/null || true
  fi

  if [[ ! -s "$diff_file" ]]; then
    echo "Error: PR diff is empty." >&2
    exit 2
  fi

  # Optional safety valve: truncate only if user explicitly sets --max-diff-lines > 0.
  # Default (0) reviews the full diff — chunking handles arbitrarily large diffs.
  local diff_lines
  diff_lines=$(wc -l < "$diff_file" | tr -d ' ')
  if [[ "$MAX_DIFF_LINES" -gt 0 && "$diff_lines" -gt "$MAX_DIFF_LINES" ]]; then
    echo "Warning: Diff is $diff_lines lines; truncating to $MAX_DIFF_LINES per --max-diff-lines. This drops $((diff_lines - MAX_DIFF_LINES)) lines from the review." >&2
    local truncated="$WORK_DIR/diff-truncated.txt"
    head -n "$MAX_DIFF_LINES" "$diff_file" > "$truncated"
    printf '\n\n... (diff truncated at %s lines)\n' "$MAX_DIFF_LINES" >> "$truncated"
    mv "$truncated" "$diff_file"
    diff_lines="$MAX_DIFF_LINES"
  fi

  # Gather project rules
  echo "Checking for CLAUDE.md..." >&2
  local project_rules
  project_rules=$(gather_project_rules)

  # Build PR-wide manifest of files and symbols (v2 P1: via plan.js when
  # available; v1 grep-based fallback otherwise). plan.js also writes
  # plan.json with per-chunk neighbors so the chunked path can splice them.
  echo "Building PR plan + manifest..." >&2
  local manifest_file="$WORK_DIR/manifest.md"
  build_plan_and_manifest "$diff_file" "$manifest_file"

  # Route: single review vs chunked review
  if [[ "$diff_lines" -le "$CHUNK_SIZE" ]]; then
    echo "Diff is $diff_lines lines (within chunk size $CHUNK_SIZE), using single review." >&2
    run_single_review "$pr_number" "$pr_title" "$head_branch" "$base_branch" "$diff_file" "$project_rules" "$followup_context" "$manifest_file"
  else
    echo "Diff is $diff_lines lines (exceeds chunk size $CHUNK_SIZE), using chunked review." >&2
    run_chunked_review "$pr_number" "$pr_title" "$head_branch" "$base_branch" "$diff_file" "$project_rules" "$followup_context" "$manifest_file"
  fi

  # Format and post (same for both paths — both produce codex-output.json)
  echo "Formatting results..." >&2
  local comment
  comment=$(format_comment "$WORK_DIR/codex-output.json" "$pr_url" "$review_iteration" "$head_sha")

  echo "Posting review to PR #$pr_number..." >&2
  echo "$comment" > "$WORK_DIR/pr-comment.md"
  if ! gh pr comment "$pr_number" --body-file "$WORK_DIR/pr-comment.md" 2>"$WORK_DIR/gh-stderr.log"; then
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
  local filtered_count total_findings resolved_count
  total_findings=$(jq '.findings | length' "$WORK_DIR/codex-output.json")
  filtered_count=$(jq --arg t "$THRESHOLD" '[.findings[] | select(.confidence_score >= ($t | tonumber))] | length' "$WORK_DIR/codex-output.json")
  resolved_count=$(jq '[.resolved_prior_findings // [] | length] | .[0]' "$WORK_DIR/codex-output.json")

  jq -n \
    --arg pr_url "$pr_url" \
    --arg pr_number "$pr_number" \
    --arg verdict "$(jq -r '.overall_correctness' "$WORK_DIR/codex-output.json")" \
    --arg confidence "$(jq -r '.overall_confidence_score' "$WORK_DIR/codex-output.json")" \
    --arg explanation "$(jq -r '.overall_explanation' "$WORK_DIR/codex-output.json")" \
    --argjson total "$total_findings" \
    --argjson reported "$filtered_count" \
    --argjson resolved "$resolved_count" \
    --argjson iteration "$review_iteration" \
    --arg threshold "$THRESHOLD" \
    --arg model "$MODEL" \
    '{
      status: "success",
      pr_url: $pr_url,
      pr_number: $pr_number,
      model: $model,
      threshold: $threshold,
      review_iteration: $iteration,
      verdict: $verdict,
      overall_confidence: $confidence,
      explanation: $explanation,
      total_findings: $total,
      reported_findings: $reported,
      resolved_findings: $resolved
    }'

  echo "Review posted to $pr_url" >&2
}

main
