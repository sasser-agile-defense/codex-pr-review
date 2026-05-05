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
# v2 P2: lowered from 6 → 4 because each slot now runs Codex AND Claude in
# parallel (so the worst-case concurrency doubles). User-tunable via
# --max-parallel.
MAX_PARALLEL="4"
VERIFY_ENABLED="true"
PR_ARG=""

# v2 additions (P1):
CHUNKER="auto"           # auto | ast | hunk
REVIEW_RULES_ARG=""      # path to override REVIEW.md / CLAUDE.md
MODEL_CODEX="gpt-5.3-codex"
MODEL_CLAUDE="claude-opus-4-7"

# v2 additions (P2):
MODEL_VERIFIER="claude-haiku-4-5"   # default cross-family verifier model

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
    --model-verifier)
      MODEL_VERIFIER="$2"
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
  --model-claude MODEL   Claude model (default claude-opus-4-7)
  --model-verifier MODEL Cross-family verifier model (default claude-haiku-4-5)
  --chunker MODE         auto | ast | hunk (default auto)
  --review-rules PATH    Path to REVIEW.md override (must exist)
  --max-diff-lines N     Truncate diff at N lines (0 = unlimited)
  --chunk-size N         Lines per chunk (default 3000)
  --max-parallel N       Concurrent slots during chunked review (default 4; each slot runs Codex+Claude in parallel)
  --no-verify            Skip the cross-family verifier (debug only)
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

  # ─── V2 prereqs (P2) ────────────────────────────────────────────────────
  # `claude` CLI is required for the dual-family pipeline and the cross-family
  # verifier. We surface it as a warning here and hard-fail at the call sites
  # (review_chunk_claude / run_cross_family_verifier) so the error message
  # carries useful context. Single-Codex v1 callers are unaffected.
  if ! command -v claude &>/dev/null; then
    echo "Note: claude CLI not found on PATH. The v2 dual-family review and cross-family verifier require it (install: https://claude.com/claude-code). Proceeding; the Claude reviewer and verifier will fail gracefully when invoked." >&2
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

# ─── Build Chunk Prompt (file-based, family-parameterized) ──────────────────
# Internal worker. Both families splice identical inputs (manifest, neighbors,
# review rules, project rules, follow-up context, diff) into a different
# prompt template file. The codex family uses scripts/codex-chunk-prompt.md;
# the claude family uses scripts/claude-chunk-prompt.md.
_build_chunk_prompt_for_family() {
  local family="$1"            # codex | claude
  local pr_number="$2"
  local pr_title="$3"
  local head_branch="$4"
  local base_branch="$5"
  local diff_file="$6"
  local project_rules="$7"
  local chunk_num="$8"
  local total_chunks="$9"
  local followup_context="${10}"
  local manifest_file="${11}"
  local output_file="${12}"

  local template_path
  case "$family" in
    codex)  template_path="$SCRIPT_DIR/codex-chunk-prompt.md" ;;
    claude) template_path="$SCRIPT_DIR/claude-chunk-prompt.md" ;;
    *)
      echo "Error: _build_chunk_prompt_for_family: unknown family '$family'" >&2
      return 1
      ;;
  esac

  # v2: project_rules → {{REVIEW_RULES}}; {{PROJECT_RULES}} kept empty.
  local review_rules_section="$project_rules"
  local project_rules_section=""

  local manifest_content=""
  if [[ -n "$manifest_file" && -f "$manifest_file" ]]; then
    manifest_content=$(cat "$manifest_file")
  fi

  local neighbors_content
  neighbors_content=$(read_plan_neighbors "$chunk_num")
  if [[ -z "$neighbors_content" ]]; then
    neighbors_content="_No cross-chunk neighbors detected._"
  fi

  local pre_file="$WORK_DIR/_chunk_template_pre_${family}_${chunk_num}.md"
  local mid_file="$WORK_DIR/_chunk_template_${family}_${chunk_num}.md"

  LC_ALL=C sed \
    -e "s|{{PR_NUMBER}}|${pr_number}|g" \
    -e "s|{{PR_TITLE}}|${pr_title}|g" \
    -e "s|{{HEAD_BRANCH}}|${head_branch}|g" \
    -e "s|{{BASE_BRANCH}}|${base_branch}|g" \
    -e "s|{{CHUNK_NUM}}|${chunk_num}|g" \
    -e "s|{{TOTAL_CHUNKS}}|${total_chunks}|g" \
    "$template_path" > "$pre_file"

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
  ' "$pre_file" > "$mid_file"

  local line_num
  line_num=$(grep -n '{{DIFF}}' "$mid_file" | head -1 | cut -d: -f1)
  if [[ -n "$line_num" ]]; then
    head -n "$((line_num - 1))" "$mid_file" > "$output_file"
    cat "$diff_file" >> "$output_file"
    tail -n "+$((line_num + 1))" "$mid_file" >> "$output_file"
  else
    cp "$mid_file" "$output_file"
  fi
}

# v1-compatible wrapper (codex family).
build_chunk_prompt() {
  _build_chunk_prompt_for_family codex "$@"
}

# v2 (P2): Claude family chunk prompt.
build_chunk_prompt_claude() {
  _build_chunk_prompt_for_family claude "$@"
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

# ─── Review Single Chunk — Codex family (background job) ────────────────────
# Reads chunk-prompt-codex-N.md, writes chunk-output-codex-NNN.json and
# chunk-stderr-codex-N.log. Same retry loop as v1.
review_chunk_codex() {
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

  local prompt_file="$WORK_DIR/chunk-prompt-codex-${chunk_num}.md"
  build_chunk_prompt "$pr_number" "$pr_title" "$head_branch" "$base_branch" \
    "$chunk_file" "$project_rules" "$chunk_num" "$total_chunks" "$followup_context" "$manifest_file" "$prompt_file"

  local max_attempts=3
  local attempt=0
  local backoffs=(0 2 5)
  while [[ $attempt -lt $max_attempts ]]; do
    attempt=$((attempt + 1))
    if codex exec \
      --model "$MODEL_CODEX" \
      --output-schema "$WORK_DIR/codex-output-schema.json" \
      --sandbox read-only \
      - < "$prompt_file" > "$output_file" 2>"$WORK_DIR/chunk-stderr-codex-${chunk_num}.log"; then
      if jq empty "$output_file" 2>/dev/null; then
        echo "  Chunk $chunk_num/$total_chunks [codex] completed$([ $attempt -gt 1 ] && echo " (retry $((attempt-1)))")." >&2
        return 0
      fi
    fi
    if [[ $attempt -lt $max_attempts ]]; then
      sleep "${backoffs[$attempt]}"
    fi
  done

  echo "  Chunk $chunk_num/$total_chunks [codex] FAILED after $max_attempts attempts." >&2
  return 1
}

# ─── Review Single Chunk — Claude family (background job) ───────────────────
# Reads chunk-prompt-claude-N.md, writes chunk-output-claude-NNN.json and
# chunk-stderr-claude-N.log.
#
# Schema enforcement: Claude CLI exposes `--json-schema <schema>` for
# structured-output validation (analogous to `codex exec --output-schema`).
# We pass the same codex-output-schema.json so both families produce
# schema-equivalent outputs that the verifier and synthesizer can merge
# uniformly.
review_chunk_claude() {
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

  if ! command -v claude &>/dev/null; then
    echo "  Chunk $chunk_num/$total_chunks [claude] SKIPPED: claude CLI not found on PATH (install Claude Code; the Codex family will continue)." >&2
    return 1
  fi

  local prompt_file="$WORK_DIR/chunk-prompt-claude-${chunk_num}.md"
  build_chunk_prompt_claude "$pr_number" "$pr_title" "$head_branch" "$base_branch" \
    "$chunk_file" "$project_rules" "$chunk_num" "$total_chunks" "$followup_context" "$manifest_file" "$prompt_file"

  local stderr_log="$WORK_DIR/chunk-stderr-claude-${chunk_num}.log"
  local schema_path="$WORK_DIR/codex-output-schema.json"
  local schema_str
  schema_str=$(cat "$schema_path")

  local max_attempts=3
  local attempt=0
  local backoffs=(0 2 5)
  while [[ $attempt -lt $max_attempts ]]; do
    attempt=$((attempt + 1))
    # `claude --print` reads the prompt from stdin, validates the response
    # against `--json-schema` (the canonical structured-output flag in this
    # CLI build), and writes the JSON object to stdout. `--allowedTools
    # Read,Grep` mirrors the spec's repo-read access requirement (§4.3).
    if claude \
      --model "$MODEL_CLAUDE" \
      --json-schema "$schema_str" \
      --output-format json \
      --allowedTools Read,Grep \
      --print \
      - < "$prompt_file" > "$output_file" 2>"$stderr_log"; then
      # `--output-format json` wraps the structured output inside a CLI
      # envelope (`{ "result": "<json string>", ... }`). Unwrap it; if the
      # field is absent (older CLI build), fall back to using the raw stdout.
      if jq empty "$output_file" 2>/dev/null; then
        local result_field
        result_field=$(jq -r 'if has("result") then .result else empty end' "$output_file" 2>/dev/null || true)
        if [[ -n "$result_field" ]]; then
          if printf '%s' "$result_field" | jq empty 2>/dev/null; then
            printf '%s' "$result_field" > "$output_file"
          fi
        fi
        if jq empty "$output_file" 2>/dev/null; then
          echo "  Chunk $chunk_num/$total_chunks [claude] completed$([ $attempt -gt 1 ] && echo " (retry $((attempt-1)))")." >&2
          return 0
        fi
      fi
    fi
    if [[ $attempt -lt $max_attempts ]]; then
      sleep "${backoffs[$attempt]}"
    fi
  done

  echo "  Chunk $chunk_num/$total_chunks [claude] FAILED after $max_attempts attempts." >&2
  return 1
}

# ─── Review Single Chunk — Both families in parallel ────────────────────────
# Launches review_chunk_codex and review_chunk_claude as concurrent background
# jobs and waits for each independently, recording per-family success / failure
# to chunk-stats-codex.txt / chunk-stats-claude.txt. One family's failure does
# NOT cancel the other (graceful degradation).
review_chunk_both() {
  local chunk_file="$1"
  local chunk_num="$2"
  local total_chunks="$3"
  local pr_number="$4"
  local pr_title="$5"
  local head_branch="$6"
  local base_branch="$7"
  local project_rules="$8"
  local codex_output="$9"
  local claude_output="${10}"
  local followup_context="${11}"
  local manifest_file="${12}"

  review_chunk_codex \
    "$chunk_file" "$chunk_num" "$total_chunks" \
    "$pr_number" "$pr_title" "$head_branch" "$base_branch" \
    "$project_rules" "$codex_output" "$followup_context" "$manifest_file" &
  local codex_pid=$!

  review_chunk_claude \
    "$chunk_file" "$chunk_num" "$total_chunks" \
    "$pr_number" "$pr_title" "$head_branch" "$base_branch" \
    "$project_rules" "$claude_output" "$followup_context" "$manifest_file" &
  local claude_pid=$!

  local codex_rc=0 claude_rc=0
  wait "$codex_pid"  || codex_rc=$?
  wait "$claude_pid" || claude_rc=$?

  printf 'chunk=%s rc=%s\n' "$chunk_num" "$codex_rc"  >> "$WORK_DIR/chunk-stats-codex.txt"
  printf 'chunk=%s rc=%s\n' "$chunk_num" "$claude_rc" >> "$WORK_DIR/chunk-stats-claude.txt"

  # Always return 0; the caller inspects the two output files (and the stats
  # files) to decide whether the chunk has any usable output.
  return 0
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

  # Reset per-family stats files (each chunk's review_chunk_both appends).
  : > "$WORK_DIR/chunk-stats-codex.txt"
  : > "$WORK_DIR/chunk-stats-claude.txt"

  # v2 fan-out: each MAX_PARALLEL slot now runs Codex AND Claude in parallel
  # (one review_chunk_both background job spawns two model processes). Worst
  # case concurrent processes per batch = MAX_PARALLEL * 2.
  echo "Launching chunk reviews ($total_chunks total, max $MAX_PARALLEL slots × 2 families = up to $((MAX_PARALLEL * 2)) concurrent processes)..." >&2
  local batch_pids=()

  for i in $(seq 1 "$total_chunks"); do
    local padded
    padded=$(printf "%03d" "$i")
    local chunk_file="$chunk_dir/chunk_${padded}.diff"
    local codex_output="$WORK_DIR/chunk-output-codex-${padded}.json"
    local claude_output="$WORK_DIR/chunk-output-claude-${padded}.json"

    review_chunk_both "$chunk_file" "$i" "$total_chunks" \
      "$pr_number" "$pr_title" "$head_branch" "$base_branch" \
      "$project_rules" "$codex_output" "$claude_output" \
      "$followup_context" "$manifest_file" &
    batch_pids+=($!)

    if [[ ${#batch_pids[@]} -ge $MAX_PARALLEL ]]; then
      for p in "${batch_pids[@]}"; do
        wait "$p" || true
      done
      batch_pids=()
    fi
  done

  for p in "${batch_pids[@]}"; do
    wait "$p" || true
  done

  # Per-family success counts.
  local codex_succeeded=0 codex_failed=0
  local claude_succeeded=0 claude_failed=0
  for i in $(seq 1 "$total_chunks"); do
    local padded
    padded=$(printf "%03d" "$i")
    local codex_out="$WORK_DIR/chunk-output-codex-${padded}.json"
    local claude_out="$WORK_DIR/chunk-output-claude-${padded}.json"
    if [[ -f "$codex_out" ]] && jq empty "$codex_out" 2>/dev/null; then
      codex_succeeded=$((codex_succeeded + 1))
    else
      codex_failed=$((codex_failed + 1))
    fi
    if [[ -f "$claude_out" ]] && jq empty "$claude_out" 2>/dev/null; then
      claude_succeeded=$((claude_succeeded + 1))
    else
      claude_failed=$((claude_failed + 1))
    fi
  done

  echo "Chunk reviews complete: codex $codex_succeeded/$total_chunks ok, claude $claude_succeeded/$total_chunks ok." >&2

  # Aggregate chunk-stats.txt for format_comment (counts a chunk as "succeeded"
  # when at least one family produced valid JSON; this preserves v1's incomplete-
  # coverage warning semantics under the dual-family layout).
  local agg_succeeded=0 agg_failed=0
  for i in $(seq 1 "$total_chunks"); do
    local padded
    padded=$(printf "%03d" "$i")
    local codex_out="$WORK_DIR/chunk-output-codex-${padded}.json"
    local claude_out="$WORK_DIR/chunk-output-claude-${padded}.json"
    if { [[ -f "$codex_out" ]] && jq empty "$codex_out" 2>/dev/null; } || \
       { [[ -f "$claude_out" ]] && jq empty "$claude_out" 2>/dev/null; }; then
      agg_succeeded=$((agg_succeeded + 1))
    else
      agg_failed=$((agg_failed + 1))
    fi
  done
  printf '%s\n%s\n' "$agg_succeeded" "$agg_failed" > "$WORK_DIR/chunk-stats.txt"

  if [[ "$agg_succeeded" -eq 0 ]]; then
    echo "Error: All chunk reviews failed (both families)." >&2
    for i in $(seq 1 "$total_chunks"); do
      local fam
      for fam in codex claude; do
        local stderr_file="$WORK_DIR/chunk-stderr-${fam}-${i}.log"
        if [[ -f "$stderr_file" && -s "$stderr_file" ]]; then
          echo "--- Chunk $i [$fam] stderr ---" >&2
          cat "$stderr_file" >&2
        fi
      done
    done
    exit 3
  fi

  # Cross-family grounded verifier (default) → writes merged-findings.json.
  # --no-verify produces a raw union with verifier_verdict=n/a.
  run_cross_family_verifier "$total_chunks" "$diff_file"

  local merged_file="$WORK_DIR/merged-findings.json"
  if [[ ! -s "$merged_file" ]] || ! jq empty "$merged_file" 2>/dev/null; then
    echo "Error: cross-family verifier did not produce a valid merged-findings.json." >&2
    exit 3
  fi

  # Build chunk results JSON array consumed by synthesis. Now feeds the
  # post-verifier merged finding list (one synthetic chunk wrapper) instead of
  # the raw per-chunk results array.
  echo "Synthesizing merged review findings..." >&2
  local chunk_results_file="$WORK_DIR/chunk-results.json"
  jq -n --slurpfile m "$merged_file" '
    [
      {
        chunk: 0,
        result: {
          findings: $m[0],
          overall_correctness: "patch is correct",
          overall_explanation: "Pre-verified merged findings from cross-family grounded verifier (see source/verifier_verdict/agreement fields).",
          overall_confidence_score: 0.5,
          review_iteration: 1,
          resolved_prior_findings: []
        }
      }
    ]
  ' > "$chunk_results_file"

  # Build and run synthesis prompt
  local synthesis_prompt_file="$WORK_DIR/synthesis-prompt.md"
  build_synthesis_prompt "$pr_number" "$pr_title" "$head_branch" "$base_branch" \
    "$chunk_results_file" "$total_chunks" "$followup_context" "$diff_file" "$synthesis_prompt_file"

  echo "Running synthesis review..." >&2
  if ! codex exec \
    --model "$MODEL_CODEX" \
    --output-schema "$WORK_DIR/codex-output-schema.json" \
    --sandbox read-only \
    - < "$synthesis_prompt_file" > "$WORK_DIR/codex-output.json" 2>"$WORK_DIR/synthesis-stderr.log"; then
    echo "Error: Synthesis step failed." >&2
    if [[ -f "$WORK_DIR/synthesis-stderr.log" ]]; then
      cat "$WORK_DIR/synthesis-stderr.log" >&2
    fi
    exit 3
  fi

  if [[ ! -f "$WORK_DIR/codex-output.json" ]]; then
    echo "Error: Synthesis did not produce output." >&2
    exit 3
  fi

  if ! jq empty "$WORK_DIR/codex-output.json" 2>/dev/null; then
    echo "Error: Synthesis output is not valid JSON." >&2
    exit 3
  fi
}

# ─── Finding ID hash ────────────────────────────────────────────────────────
# Stable per-finding identifier: SHA-256 of `<file>|<start_line>|<title>`,
# first 8 hex chars. Inputs come from code_location.path,
# code_location.start_line, and title. Identical inputs yield identical IDs
# across runs (verified in tests/test-verifier.sh).
finding_id() {
  local file="$1"
  local start_line="$2"
  local title="$3"
  local key="${file}|${start_line}|${title}"
  if command -v shasum &>/dev/null; then
    printf '%s' "$key" | shasum -a 256 | cut -c1-8
  elif command -v openssl &>/dev/null; then
    printf '%s' "$key" | openssl dgst -sha256 | awk '{print $NF}' | cut -c1-8
  else
    # Fallback: deterministic but non-cryptographic. Not used in CI.
    printf '%s' "$key" | cksum | awk '{printf "%08x", $1}'
  fi
}

# ─── Verifier subprocess: Claude Haiku verifies a Codex finding ─────────────
# Writes verifier verdict JSON to stdout (verdict|evidence|adjusted_confidence).
# Returns non-zero if the verifier itself failed (auth, timeout, parse error);
# the caller should treat that as `inconclusive` per spec §7.
_run_claude_verifier() {
  local prompt_file="$1"
  local out_file="$2"
  local stderr_log="$3"
  local verifier_model="${4:-$MODEL_VERIFIER}"
  local schema_str
  schema_str=$(cat "$SCRIPT_DIR/verifier-output-schema.json")

  if ! command -v claude &>/dev/null; then
    echo "claude CLI missing" > "$stderr_log"
    return 1
  fi

  if claude \
    --model "$verifier_model" \
    --json-schema "$schema_str" \
    --output-format json \
    --allowedTools Read,Grep \
    --print \
    - < "$prompt_file" > "$out_file" 2>"$stderr_log"; then
    if jq empty "$out_file" 2>/dev/null; then
      local result_field
      result_field=$(jq -r 'if has("result") then .result else empty end' "$out_file" 2>/dev/null || true)
      if [[ -n "$result_field" ]] && printf '%s' "$result_field" | jq empty 2>/dev/null; then
        printf '%s' "$result_field" > "$out_file"
      fi
      if jq -e '.verdict and .evidence and (.adjusted_confidence != null)' "$out_file" >/dev/null 2>&1; then
        return 0
      fi
    fi
  fi
  return 1
}

# ─── Verifier subprocess: Codex CLI verifies a Claude finding ───────────────
_run_codex_verifier() {
  local prompt_file="$1"
  local out_file="$2"
  local stderr_log="$3"
  if codex exec \
    --model "$MODEL_CODEX" \
    --output-schema "$SCRIPT_DIR/verifier-output-schema.json" \
    --sandbox read-only \
    - < "$prompt_file" > "$out_file" 2>"$stderr_log"; then
    if jq -e '.verdict and .evidence and (.adjusted_confidence != null)' "$out_file" >/dev/null 2>&1; then
      return 0
    fi
  fi
  return 1
}

# ─── Build a verifier prompt (file-based) ───────────────────────────────────
# Splices {{REVIEW_RULES}}, {{FINDING}}, {{FILE_PATH}}, {{FILE_CONTENT}},
# {{DIFF_HUNK}} into the family-appropriate template.
_build_verifier_prompt() {
  local template_path="$1"
  local out_file="$2"
  local review_rules="$3"
  local finding_json="$4"
  local file_path="$5"
  local file_content_path="$6"   # path to file containing the file content
  local diff_hunk_path="$7"      # path to file containing the relevant diff hunk

  local file_content=""
  [[ -f "$file_content_path" ]] && file_content=$(cat "$file_content_path")
  local diff_hunk=""
  [[ -f "$diff_hunk_path" ]] && diff_hunk=$(cat "$diff_hunk_path")

  REVIEW_RULES_VAL="$review_rules" \
  FINDING_VAL="$finding_json" \
  FILE_PATH_VAL="$file_path" \
  FILE_CONTENT_VAL="$file_content" \
  DIFF_HUNK_VAL="$diff_hunk" \
  perl -pe '
    BEGIN {
      $rr = $ENV{REVIEW_RULES_VAL};
      $fd = $ENV{FINDING_VAL};
      $fp = $ENV{FILE_PATH_VAL};
      $fc = $ENV{FILE_CONTENT_VAL};
      $dh = $ENV{DIFF_HUNK_VAL};
    }
    s/\Q{{REVIEW_RULES}}\E/$rr/g;
    s/\Q{{FINDING}}\E/$fd/g;
    s/\Q{{FILE_PATH}}\E/$fp/g;
    s/\Q{{FILE_CONTENT}}\E/$fc/g;
    s/\Q{{DIFF_HUNK}}\E/$dh/g;
  ' "$template_path" > "$out_file"
}

# ─── Extract the diff hunk that covers a given file/line range ──────────────
# Best-effort: scans the full diff for the file's `diff --git` entry, then
# finds the closest enclosing @@ hunk. Writes the hunk to $out_file. If the
# file is not in the diff, writes "(file not present in diff)".
_extract_diff_hunk() {
  local diff_file="$1"
  local file_path="$2"
  local start_line="$3"
  local out_file="$4"

  awk -v target="$file_path" -v start="$start_line" '
    BEGIN { in_file=0; in_hunk=0; new_start=0; new_count=0; buf=""; matched=""; }
    /^diff --git / {
      if (in_file && matched != "") { print matched; }
      in_file = 0; in_hunk=0; matched=""; buf=""
      # Capture the b/<path> token and compare to target.
      if (match($0, /b\/[^ ]+/)) {
        b_path = substr($0, RSTART+2, RLENGTH-2)
        if (b_path == target) { in_file = 1 }
      }
      next
    }
    /^@@ / {
      if (!in_file) next
      # Save the prior hunk if it covered start
      if (in_hunk && new_start <= start && start <= new_start + new_count) {
        matched = buf
      }
      buf = $0 "\n"
      in_hunk = 1
      # Parse new file range from "+a,b" segment
      if (match($0, /\+[0-9]+(,[0-9]+)?/)) {
        seg = substr($0, RSTART+1, RLENGTH-1)
        n = split(seg, parts, ",")
        new_start = parts[1] + 0
        new_count = (n >= 2 ? parts[2] + 0 : 1)
      }
      next
    }
    {
      if (in_file && in_hunk) buf = buf $0 "\n"
    }
    END {
      if (in_file && in_hunk && new_start <= start && start <= new_start + new_count) {
        matched = buf
      }
      if (matched != "") { printf "%s", matched }
    }
  ' "$diff_file" > "$out_file"

  if [[ ! -s "$out_file" ]]; then
    printf '(file not present in diff or hunk could not be located)\n' > "$out_file"
  fi
}

# ─── Cross-family Grounded Verifier (v2 P2) ─────────────────────────────────
# Reads chunk-output-codex-NNN.json + chunk-output-claude-NNN.json for every
# chunk, normalizes the union of findings (defensive `source` tagging,
# stable finding_id), dispatches Claude Haiku verification for codex-source
# findings and Codex CLI verification for claude-source findings (parallel,
# pool capped at min(MAX_PARALLEL*2, 8)), applies routing per spec §4.4, and
# writes $WORK_DIR/merged-findings.json. --no-verify writes the raw union
# with verifier_verdict=n/a and skips verification entirely.
run_cross_family_verifier() {
  local total_chunks="$1"
  local diff_file="$2"

  mkdir -p "$WORK_DIR/verifier"
  : > "$WORK_DIR/verifier/refuted.log"

  # Build the raw union of every (codex|claude) finding across all chunks.
  # Defensive: if a finding lacks `source`, tag it from the file it came from.
  local raw_findings_file="$WORK_DIR/verifier/raw-findings.json"
  : > "$raw_findings_file"
  printf '[' > "$raw_findings_file"
  local first=true
  local i fam padded
  for i in $(seq 1 "$total_chunks"); do
    padded=$(printf "%03d" "$i")
    for fam in codex claude; do
      local f="$WORK_DIR/chunk-output-${fam}-${padded}.json"
      [[ -f "$f" ]] || continue
      jq empty "$f" 2>/dev/null || continue
      while IFS= read -r finding; do
        [[ -z "$finding" || "$finding" == "null" ]] && continue
        if [[ "$first" == "true" ]]; then
          first=false
        else
          printf ',' >> "$raw_findings_file"
        fi
        # Force-tag source defensively, then attach finding_id.
        local fid
        local file_path start_line title
        file_path=$(printf '%s' "$finding" | jq -r '.code_location.path // ""')
        start_line=$(printf '%s' "$finding" | jq -r '.code_location.start_line // 0')
        title=$(printf '%s' "$finding" | jq -r '.title // ""')
        fid=$(finding_id "$file_path" "$start_line" "$title")
        printf '%s' "$finding" \
          | jq -c --arg fam "$fam" --arg fid "$fid" \
              '. + {source: (.source // $fam), _finding_id: $fid}' \
          >> "$raw_findings_file"
      done < <(jq -c '.findings[]?' "$f" 2>/dev/null)
    done
  done
  printf ']' >> "$raw_findings_file"

  if ! jq empty "$raw_findings_file" 2>/dev/null; then
    echo "Warning: raw findings union is invalid JSON; emitting empty merged-findings.json." >&2
    printf '[]' > "$WORK_DIR/merged-findings.json"
    return 0
  fi

  local raw_count
  raw_count=$(jq 'length' "$raw_findings_file")
  echo "Cross-family verifier input: $raw_count raw findings (codex+claude union)." >&2

  # --no-verify path: short-circuit. Mark every finding as n/a, derive
  # `agreement` by checking duplicates across families on (file,start_line,title).
  if [[ "$VERIFY_ENABLED" != "true" ]]; then
    echo "Skipping cross-family verifier (--no-verify); writing raw union." >&2
    jq '
      def key(f): (f.code_location.path // "") + "|" + ((f.code_location.start_line // 0)|tostring) + "|" + (f.title // "");
      . as $all
      | group_by(key(.)) as $groups
      | $groups
      | map(
          (.[0] | . + {
            verifier_verdict: "n/a",
            agreement: (
              if (map(.source) | (any(. == "codex") and any(. == "claude"))) then "both"
              elif .[0].source == "codex" then "codex-only"
              else "claude-only" end
            )
          })
        )
      | map(del(._finding_id))
    ' "$raw_findings_file" > "$WORK_DIR/merged-findings.json"
    return 0
  fi

  # Compute paired-set for `both` agreement: a finding has agreement=both if
  # there's a sibling finding from the other family with the same (file,
  # start_line, title) key. We emit a side-table mapping each _finding_id to
  # the sibling family set.
  local sibling_map_file="$WORK_DIR/verifier/sibling-map.json"
  jq '
    def key(f): (f.code_location.path // "") + "|" + ((f.code_location.start_line // 0)|tostring) + "|" + (f.title // "");
    [.[] | {fid: ._finding_id, key: key(.), source}]
    | group_by(.key)
    | map(
        . as $g
        | $g | map({(.fid): {key: .key, families: ($g | map(.source) | unique)}})
        | add
      )
    | add // {}
  ' "$raw_findings_file" > "$sibling_map_file"

  # Dispatch verifier subprocess per finding, parallel with cap.
  local verifier_cap=$(( MAX_PARALLEL * 2 ))
  if [[ "$verifier_cap" -gt 8 ]]; then verifier_cap=8; fi
  if [[ "$verifier_cap" -lt 1 ]]; then verifier_cap=1; fi
  echo "Dispatching verifier jobs (pool cap $verifier_cap)..." >&2

  local review_rules
  review_rules=$(gather_project_rules)

  local pids=()
  local idx
  local raw_len
  raw_len=$(jq 'length' "$raw_findings_file")
  for ((idx=0; idx<raw_len; idx++)); do
    local finding
    finding=$(jq -c --argjson i "$idx" '.[$i]' "$raw_findings_file")
    local source fid file_path start_line title
    source=$(printf '%s' "$finding" | jq -r '.source')
    fid=$(printf '%s' "$finding" | jq -r '._finding_id')
    file_path=$(printf '%s' "$finding" | jq -r '.code_location.path // ""')
    start_line=$(printf '%s' "$finding" | jq -r '.code_location.start_line // 0')
    title=$(printf '%s' "$finding" | jq -r '.title')

    # Background subprocess: write verdict file at $WORK_DIR/verifier/finding-<id>-verdict.json
    (
      local verdict_file="$WORK_DIR/verifier/finding-${fid}-verdict.json"
      local stderr_log="$WORK_DIR/verifier/finding-${fid}-stderr.log"
      local file_content_path="$WORK_DIR/verifier/finding-${fid}-file.txt"
      local hunk_path="$WORK_DIR/verifier/finding-${fid}-hunk.diff"
      local prompt_file="$WORK_DIR/verifier/finding-${fid}-prompt.md"

      # Read file at HEAD; if it does not exist there, the verifier will
      # treat the finding as refuted (line cannot exist).
      if [[ -n "$file_path" ]] && git show "HEAD:${file_path}" > "$file_content_path" 2>/dev/null; then
        :
      else
        printf '(file not present at HEAD: %s)\n' "$file_path" > "$file_content_path"
      fi

      _extract_diff_hunk "$diff_file" "$file_path" "$start_line" "$hunk_path"

      local template
      if [[ "$source" == "codex" ]]; then
        template="$SCRIPT_DIR/verifier-claude-prompt.md"
      else
        template="$SCRIPT_DIR/verifier-codex-prompt.md"
      fi

      _build_verifier_prompt "$template" "$prompt_file" "$review_rules" \
        "$finding" "$file_path" "$file_content_path" "$hunk_path"

      # Primary verifier dispatch.
      local verifier_ok=0
      if [[ "$source" == "codex" ]]; then
        if _run_claude_verifier "$prompt_file" "$verdict_file" "$stderr_log" "$MODEL_VERIFIER"; then
          verifier_ok=1
        fi
      else
        if _run_codex_verifier "$prompt_file" "$verdict_file" "$stderr_log"; then
          verifier_ok=1
        fi
      fi

      # Escalation on inconclusive (or primary failure): rerun with the Opus
      # verifier on the Claude side, or reasoning-high (default config) on the
      # Codex side. Keep the highest-quality verdict.
      local verdict
      verdict=$(jq -r '.verdict // "inconclusive"' "$verdict_file" 2>/dev/null || echo "inconclusive")
      if [[ "$verifier_ok" -ne 1 ]] || [[ "$verdict" == "inconclusive" ]]; then
        local escalated_verdict_file="$WORK_DIR/verifier/finding-${fid}-verdict-escalated.json"
        local escalated_stderr_log="$WORK_DIR/verifier/finding-${fid}-stderr-escalated.log"
        if [[ "$source" == "codex" ]]; then
          if _run_claude_verifier "$prompt_file" "$escalated_verdict_file" "$escalated_stderr_log" "claude-opus-4-7"; then
            mv "$escalated_verdict_file" "$verdict_file"
            verifier_ok=1
            verdict=$(jq -r '.verdict // "inconclusive"' "$verdict_file" 2>/dev/null || echo "inconclusive")
          fi
        else
          if _run_codex_verifier "$prompt_file" "$escalated_verdict_file" "$escalated_stderr_log"; then
            mv "$escalated_verdict_file" "$verdict_file"
            verifier_ok=1
            verdict=$(jq -r '.verdict // "inconclusive"' "$verdict_file" 2>/dev/null || echo "inconclusive")
          fi
        fi
      fi

      if [[ "$verifier_ok" -ne 1 ]]; then
        # Synthesize an inconclusive verdict so downstream merge has something
        # to consume.
        printf '{"verdict":"inconclusive","evidence":"verifier subprocess failed (auth/timeout/parse). See finding-%s-stderr.log.","adjusted_confidence":0.0}\n' "$fid" > "$verdict_file"
      fi
    ) &
    pids+=($!)

    if [[ ${#pids[@]} -ge "$verifier_cap" ]]; then
      for p in "${pids[@]}"; do
        wait "$p" || true
      done
      pids=()
    fi
  done
  for p in "${pids[@]}"; do
    wait "$p" || true
  done

  # Merge step: walk the raw findings, attach the verdict, apply routing.
  echo "Merging verifier verdicts into final findings list..." >&2
  local merged_file="$WORK_DIR/merged-findings.json"
  : > "$merged_file"
  printf '[' > "$merged_file"
  local merged_first=true
  local refuted_count=0
  local total_count=0

  for ((idx=0; idx<raw_len; idx++)); do
    total_count=$((total_count + 1))
    local finding
    finding=$(jq -c --argjson i "$idx" '.[$i]' "$raw_findings_file")
    local source fid
    source=$(printf '%s' "$finding" | jq -r '.source')
    fid=$(printf '%s' "$finding" | jq -r '._finding_id')

    local verdict_file="$WORK_DIR/verifier/finding-${fid}-verdict.json"
    local verdict="inconclusive"
    local adjusted_conf="0.0"
    if [[ -f "$verdict_file" ]] && jq empty "$verdict_file" 2>/dev/null; then
      verdict=$(jq -r '.verdict // "inconclusive"' "$verdict_file")
      adjusted_conf=$(jq -r '.adjusted_confidence // 0.0' "$verdict_file")
    fi

    if [[ "$verdict" == "refuted" ]]; then
      refuted_count=$((refuted_count + 1))
      local title
      title=$(printf '%s' "$finding" | jq -r '.title')
      printf '%s | %s | finding_id=%s | source=%s\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$title" "$fid" "$source" \
        >> "$WORK_DIR/verifier/refuted.log"
      continue
    fi

    # Determine sibling families to compute `agreement`.
    local has_codex has_claude
    has_codex=$(jq -r --arg fid "$fid" '.[$fid].families[]? | select(. == "codex") | .' "$sibling_map_file" 2>/dev/null | head -1)
    has_claude=$(jq -r --arg fid "$fid" '.[$fid].families[]? | select(. == "claude") | .' "$sibling_map_file" 2>/dev/null | head -1)

    local agreement
    if [[ -n "$has_codex" && -n "$has_claude" ]]; then
      agreement="both"
    elif [[ "$source" == "codex" ]]; then
      agreement="codex-only"
    else
      agreement="claude-only"
    fi

    if [[ "$verdict" == "inconclusive" ]]; then
      # Spec §4.4: keep with verifier_verdict=inconclusive, demote priority,
      # multiply confidence by 0.7. Agreement label flips to unconfirmed-by-X
      # so format_comment can render the badge.
      if [[ "$source" == "codex" ]]; then
        agreement="unconfirmed-by-claude"
      else
        agreement="unconfirmed-by-codex"
      fi
    fi

    if [[ "$merged_first" == "true" ]]; then
      merged_first=false
    else
      printf ',' >> "$merged_file"
    fi

    printf '%s' "$finding" \
      | jq -c --arg verdict "$verdict" \
             --arg agreement "$agreement" \
             --argjson adjconf "$adjusted_conf" \
        '
          . as $f
          | (.confidence_score // 0.5) as $orig_conf
          | (if $verdict == "confirmed" then
               (if $adjconf > $orig_conf then $adjconf else $orig_conf end)
             elif $verdict == "inconclusive" then
               ($orig_conf * 0.7)
             else $orig_conf end) as $new_conf
          | (if $verdict == "inconclusive" and (.priority // 0) > 1
               then ((.priority // 0) - 1)
             else (.priority // 0) end) as $new_priority
          | $f
          | .verifier_verdict = $verdict
          | .agreement        = $agreement
          | .confidence_score = $new_conf
          | .priority         = $new_priority
          | del(._finding_id)
        ' >> "$merged_file"
  done
  printf ']' >> "$merged_file"

  echo "Cross-family verifier complete: $((total_count - refuted_count))/$total_count findings survived ($refuted_count refuted)." >&2

  # If parsing fell apart, write a safe empty array so downstream code does
  # not crash.
  if ! jq empty "$merged_file" 2>/dev/null; then
    echo "Warning: merged-findings.json is invalid JSON; replacing with empty array." >&2
    printf '[]' > "$merged_file"
  fi

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
      local title priority path start_line end_line conf status agreement verifier_verdict
      title=$(echo "$finding" | jq -r '.title')
      priority=$(echo "$finding" | jq -r '.priority')
      path=$(echo "$finding" | jq -r '.code_location.path')
      start_line=$(echo "$finding" | jq -r '.code_location.start_line')
      end_line=$(echo "$finding" | jq -r '.code_location.end_line')
      conf=$(echo "$finding" | jq -r '.confidence_score')
      status=$(echo "$finding" | jq -r '.status // "new"')
      agreement=$(echo "$finding" | jq -r '.agreement // ""')
      verifier_verdict=$(echo "$finding" | jq -r '.verifier_verdict // ""')

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

      # v2: prepend agreement badge.
      local badge=""
      case "$agreement" in
        both)                  badge="[both] " ;;
        codex-only)            badge="[codex-only] " ;;
        claude-only)           badge="[claude-only] " ;;
        unconfirmed-by-codex)  badge="[unconfirmed-by-codex] " ;;
        unconfirmed-by-claude) badge="[unconfirmed-by-claude] " ;;
        deterministic)         badge="[deterministic] " ;;
        "")                    badge="" ;;
        *)                     badge="[${agreement}] " ;;
      esac

      # Show status prefix for follow-up reviews
      local display_title="${badge}${title}"
      if [[ "$review_iteration" -gt 1 && "$status" == "persisting" ]]; then
        display_title="[PERSISTING] ${badge}$title"
      fi

      comment+="| $idx | $priority_label | $display_title | $location | $conf |"$'\n'
    done < <(jq -c --arg t "$THRESHOLD" '.findings[] | select(.confidence_score >= ($t | tonumber))' "$output_file" | jq -c '.' | sort -t: -k1 -rn 2>/dev/null || cat)

    comment+=$'\n'
    comment+="<details><summary>Detailed findings</summary>"$'\n\n'

    idx=0
    while IFS= read -r finding; do
      idx=$((idx + 1))
      local title body priority path start_line end_line conf status agreement verifier_verdict
      title=$(echo "$finding" | jq -r '.title')
      body=$(echo "$finding" | jq -r '.body')
      priority=$(echo "$finding" | jq -r '.priority')
      path=$(echo "$finding" | jq -r '.code_location.path')
      start_line=$(echo "$finding" | jq -r '.code_location.start_line')
      end_line=$(echo "$finding" | jq -r '.code_location.end_line')
      conf=$(echo "$finding" | jq -r '.confidence_score')
      status=$(echo "$finding" | jq -r '.status // "new"')
      agreement=$(echo "$finding" | jq -r '.agreement // ""')
      verifier_verdict=$(echo "$finding" | jq -r '.verifier_verdict // ""')

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

      local badge=""
      case "$agreement" in
        both)                  badge="[both] " ;;
        codex-only)            badge="[codex-only] " ;;
        claude-only)           badge="[claude-only] " ;;
        unconfirmed-by-codex)  badge="[unconfirmed-by-codex] " ;;
        unconfirmed-by-claude) badge="[unconfirmed-by-claude] " ;;
        deterministic)         badge="[deterministic] " ;;
        "")                    badge="" ;;
        *)                     badge="[${agreement}] " ;;
      esac

      comment+="**$idx. ${badge}$title**${status_label} (priority: $priority_label, confidence: $conf)"$'\n'
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

  # ── v2 sentinel (compact, machine-parseable; primary in v2) ──────────────
  # P4's iteration classifier reads this first; falls back to the legacy
  # CODEX_REVIEW_DATA_START block below for v1 back-compat.
  local sanitized_verdict="$verdict"
  case "$sanitized_verdict" in
    "patch is correct")    sanitized_verdict="correct" ;;
    "patch is incorrect")  sanitized_verdict="needs-changes" ;;
  esac
  comment+=$'\n\n'"<!-- codex-pr-review:meta v=2 sha=${head_sha} iteration=${review_iteration} findings=${filtered_count} verdict=${sanitized_verdict} -->"

  # Embed review data for future follow-up reviews (v1 back-compat)
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
