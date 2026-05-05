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

# v2 additions (P3): deterministic floor (lint/typecheck/tests on changed
# lines). Enabled by default; --no-deterministic disables it. The flag is
# wired through to det-floor.sh via the NO_DETERMINISTIC env var.
NO_DETERMINISTIC="false"

# v2 additions (P4):
MODE="auto"   # auto | initial | followup | delta — iteration mode override

# Smoke-test affordance: when true, write the rendered comment to stdout and to
# a stable file under /tmp instead of calling `gh pr comment`. Useful for
# verifying the v2 pipeline against a real PR without mutating the PR thread.
DRY_RUN="false"

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
    --no-deterministic)
      NO_DETERMINISTIC="true"
      shift
      ;;
    --mode)
      case "$2" in
        auto|initial|followup|delta) MODE="$2" ;;
        *) echo "Error: --mode must be auto|initial|followup|delta, got: $2" >&2; exit 1 ;;
      esac
      shift 2
      ;;
    --dry-run)
      DRY_RUN="true"
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
  --no-deterministic     Skip the deterministic lint/typecheck/test floor
  --mode MODE            auto | initial | followup | delta (default auto)
  --dry-run              Render the review but do NOT post it to the PR; write
                         it to stdout and to /tmp/codex-pr-review-dry-run-*.md
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

# Returns 0 (true) when the v2 dual-family pipeline (Codex + Claude in parallel
# + cross-family grounded verifier) can run, else 1 (false). Used to route the
# single-vs-chunked decision in main(): v2 always uses the chunked code path
# (which handles 1-chunk diffs correctly) so small PRs still get the headline
# anti-hallucination feature. v1 single-review is the graceful-degradation
# fallback when claude CLI is missing or the user opted out via --no-verify.
v2_dual_family_enabled() {
  command -v claude &>/dev/null && [[ "$VERIFY_ENABLED" == "true" ]]
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

# ─── Prior Review Detection (v1, retained for back-compat) ──────────────────
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

# ─── Prior Review Detection (v2 P4) ─────────────────────────────────────────
# Parses a PR comment body for the v2 sentinel first; falls back to the v1
# CODEX_REVIEW_DATA_START block on absence. Writes a structured object to
# stdout:
#   {found: bool, prior_sha: str, iteration: int, verdict: str, findings: [...]}
# When called with two args, the first arg is treated as a path to a fixture
# file and the second is the (unused) PR number. With one arg, it's the PR
# number and gh is queried for the latest comment with either sentinel.
_parse_v2_sentinel() {
  # Parses a single line like:
  #   <!-- codex-pr-review:meta v=2 sha=abc123 iteration=2 findings=3 verdict=needs-changes mode=delta-since-prior prior_sha=deadbeef -->
  # Outputs a JSON object via jq -n (no shell interpolation hazards).
  local line="$1"
  # Use a perl one-liner to extract k=v pairs; tolerate any order and unknown
  # extra keys.
  printf '%s' "$line" | perl -ne '
    my %kv;
    while (/\b([A-Za-z_][A-Za-z0-9_]*)=([^\s>]+)/g) { $kv{$1} = $2; }
    my $sha       = $kv{sha}       // "";
    my $iter      = $kv{iteration} // 1;
    my $findings  = $kv{findings}  // 0;
    my $verdict   = $kv{verdict}   // "";
    my $mode      = $kv{mode}      // "";
    my $prior_sha = $kv{prior_sha} // "";
    print qq({"sha":"$sha","iteration":$iter,"findings_count":$findings,"verdict":"$verdict","mode":"$mode","prior_sha_inner":"$prior_sha"});
  '
}

# Reads a PR comment body (stdin) and emits the parsed prior-review JSON to
# stdout. Used by both the live (gh) path and the test fixture path.
_extract_prior_review_from_body() {
  local body
  body=$(cat)

  # 1. v2 sentinel.
  local sentinel_line
  sentinel_line=$(printf '%s\n' "$body" | grep -m1 -- '<!-- codex-pr-review:meta v=2 ' || true)
  if [[ -n "$sentinel_line" ]]; then
    local meta_obj
    meta_obj=$(_parse_v2_sentinel "$sentinel_line")

    # The v1 data block (if also present) gives us the embedded findings.
    local data_block
    data_block=$(printf '%s\n' "$body" | sed -n '/CODEX_REVIEW_DATA_START/,/CODEX_REVIEW_DATA_END/{//d;p;}')

    local findings_arr='[]'
    if [[ -n "$data_block" ]] && printf '%s' "$data_block" | jq empty 2>/dev/null; then
      findings_arr=$(printf '%s' "$data_block" | jq -c '.output.findings // []' 2>/dev/null || echo '[]')
    fi

    jq -n --argjson meta "$meta_obj" --argjson findings "$findings_arr" '
      {
        found: true,
        prior_sha: ($meta.sha // ""),
        iteration: ($meta.iteration // 1),
        verdict: ($meta.verdict // ""),
        findings: $findings,
        raw_data: null
      }
    '
    return 0
  fi

  # 2. v1 fallback: CODEX_REVIEW_DATA_START block. No prior_sha is recorded.
  local data_block
  data_block=$(printf '%s\n' "$body" | sed -n '/CODEX_REVIEW_DATA_START/,/CODEX_REVIEW_DATA_END/{//d;p;}')
  if [[ -n "$data_block" ]] && printf '%s' "$data_block" | jq empty 2>/dev/null; then
    printf '%s' "$data_block" | jq -c '
      {
        found: true,
        prior_sha: "",
        iteration: (.review_iteration // 1),
        verdict: (.output.overall_correctness // ""),
        findings: (.output.findings // []),
        raw_data: .
      }
    '
    return 0
  fi

  # 3. Nothing found.
  printf '{"found":false,"prior_sha":"","iteration":0,"verdict":"","findings":[],"raw_data":null}\n'
  return 0
}

gather_prior_review_v2() {
  local pr_number="$1"
  local fixture_file="${2:-}"   # optional: path to a PR comment fixture (used by tests)

  local out_file="${WORK_DIR:-/tmp}/prior-review.json"

  if [[ -n "$fixture_file" ]]; then
    if [[ ! -f "$fixture_file" ]]; then
      echo "Error: gather_prior_review_v2: fixture file not found: $fixture_file" >&2
      printf '{"found":false,"prior_sha":"","iteration":0,"verdict":"","findings":[],"raw_data":null}\n' > "$out_file"
      cat "$out_file"
      return 1
    fi
    _extract_prior_review_from_body < "$fixture_file" > "$out_file"
    cat "$out_file"
    if jq -e '.found' "$out_file" >/dev/null 2>&1; then
      return 0
    fi
    return 1
  fi

  # Live path: query gh for latest review comment bodies.
  local repo
  repo=$(gh repo view --json nameWithOwner -q '.nameWithOwner' 2>/dev/null) || {
    printf '{"found":false,"prior_sha":"","iteration":0,"verdict":"","findings":[],"raw_data":null}\n' > "$out_file"
    cat "$out_file"
    return 1
  }

  # Pull comment bodies that contain either sentinel; v2 sentinel is preferred.
  local encoded_bodies
  encoded_bodies=$(gh api "repos/$repo/issues/$pr_number/comments" \
    --paginate \
    --jq '.[] | select((.body | contains("codex-pr-review:meta v=2")) or (.body | contains("CODEX_REVIEW_DATA_START"))) | .body | @base64' 2>/dev/null)

  if [[ -z "$encoded_bodies" ]]; then
    printf '{"found":false,"prior_sha":"","iteration":0,"verdict":"","findings":[],"raw_data":null}\n' > "$out_file"
    cat "$out_file"
    return 1
  fi

  # Use the most recent comment.
  local last_encoded
  last_encoded=$(echo "$encoded_bodies" | tail -1)
  local comment_body
  comment_body=$(printf '%s' "$last_encoded" | jq -Rr '@base64d')

  if [[ -z "$comment_body" ]]; then
    printf '{"found":false,"prior_sha":"","iteration":0,"verdict":"","findings":[],"raw_data":null}\n' > "$out_file"
    cat "$out_file"
    return 1
  fi

  printf '%s\n' "$comment_body" | _extract_prior_review_from_body > "$out_file"
  cat "$out_file"
  if jq -e '.found' "$out_file" >/dev/null 2>&1; then
    return 0
  fi
  return 1
}

# ─── Iteration Classifier (v2 P4) ───────────────────────────────────────────
# Inputs:
#   prior_sha — v2 prior-review SHA (may be empty for v1 priors / no prior).
#   prior_found — "true" if a prior review was located.
#   mode — auto | initial | followup | delta (forced override).
# Output (stdout): one of `initial` / `followup-after-fixes` /
# `delta-since-prior`. The `delta-since-prior` mode is only emitted when
# prior_sha is set and recent commits look non-fix-flavored.
classify_iteration() {
  local prior_sha="$1"
  local prior_found="$2"   # "true" / "false"
  local mode="${3:-auto}"

  case "$mode" in
    initial)  echo "initial"; return 0 ;;
    followup) echo "followup-after-fixes"; return 0 ;;
    delta)
      if [[ "$prior_found" != "true" ]]; then
        echo "Error: --mode delta requires a prior review, but none was found." >&2
        return 2
      fi
      echo "delta-since-prior"
      return 0
      ;;
    auto) ;;
    *) echo "Error: classify_iteration: bad mode '$mode'" >&2; return 2 ;;
  esac

  # auto mode.
  if [[ "$prior_found" != "true" ]]; then
    echo "initial"
    return 0
  fi

  if [[ -z "$prior_sha" ]]; then
    # v1 prior review, no SHA on record. Best-effort fallback.
    echo "followup-after-fixes"
    return 0
  fi

  # Allow tests to mock `git log` output by setting ITERATION_GIT_LOG_OVERRIDE.
  # The override is honored even when empty (treated as "no commits since
  # prior_sha"), distinguished from "unset" via ${var+set}.
  local git_log_output git_log_rc=0
  if [[ -n "${ITERATION_GIT_LOG_OVERRIDE+set}" ]]; then
    git_log_output="$ITERATION_GIT_LOG_OVERRIDE"
  else
    git_log_output=$(git log --oneline "${prior_sha}..HEAD" 2>/dev/null) || git_log_rc=$?
    if [[ "$git_log_rc" -ne 0 ]]; then
      echo "Warning: git log ${prior_sha}..HEAD failed (SHA not in local clone). Falling back to followup-after-fixes." >&2
      echo "  Recover full history with: git fetch --unshallow --recurse-submodules" >&2
      echo "followup-after-fixes"
      return 0
    fi
  fi

  if [[ -z "$git_log_output" ]]; then
    echo "followup-after-fixes"
    return 0
  fi

  # Count commits and how many look fix-flavored.
  local total_commits=0 fix_commits=0
  # Build regexes outside the conditional so bash 3.2 (macOS default) doesn't
  # choke on `$` inside the [[ =~ ]] expression.
  local re_fix='^[Ff]ix([[:space:]:(]|$)'
  local re_chore='^[Cc]hore([[:space:]:(]|$)'
  local re_address='^[Aa]ddress([[:space:]:(]|$)'
  local re_pr_feedback='[Pp][Rr][[:space:]]+[Ff]eedback'
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    total_commits=$((total_commits + 1))
    # The first column is the abbreviated SHA; the rest is the message.
    local msg="${line#* }"
    if [[ "$msg" =~ $re_fix ]] || \
       [[ "$msg" =~ $re_chore ]] || \
       [[ "$msg" =~ $re_address ]] || \
       [[ "$msg" =~ $re_pr_feedback ]]; then
      fix_commits=$((fix_commits + 1))
    fi
  done <<< "$git_log_output"

  if [[ "$total_commits" -gt 0 && "$fix_commits" -eq "$total_commits" ]]; then
    echo "followup-after-fixes"
  else
    echo "delta-since-prior"
  fi
  return 0
}

# ─── Compute delta diff for delta-since-prior mode ──────────────────────────
# Writes git diff $prior_sha..HEAD to $WORK_DIR/delta-diff.txt. On failure
# (SHA not in local clone), emits a warning that includes the exact recovery
# command and returns non-zero so the caller can fall back to the full diff.
compute_delta_diff() {
  local prior_sha="$1"
  local out_file="$2"

  if [[ -z "$prior_sha" ]]; then
    echo "Error: compute_delta_diff: prior_sha is empty" >&2
    return 1
  fi

  # Allow tests to mock the diff output. Honor empty overrides (the test may
  # set the variable to an empty string to simulate "no commits"), checking
  # ${var+set} rather than -n.
  if [[ -n "${ITERATION_GIT_DIFF_OVERRIDE+set}" ]]; then
    printf '%s' "$ITERATION_GIT_DIFF_OVERRIDE" > "$out_file"
    return 0
  fi

  if ! git diff "${prior_sha}..HEAD" > "$out_file" 2>/dev/null; then
    echo "Warning: git diff ${prior_sha}..HEAD failed (SHA not present in local clone)." >&2
    echo "  Falling back to full PR diff. To recover full history, run:" >&2
    echo "    git fetch --unshallow --recurse-submodules" >&2
    rm -f "$out_file"
    return 1
  fi
  return 0
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

# ─── Build Follow-up Context (v1, retained for back-compat) ────────────────
build_followup_context() {
  local prior_review_json="$1"
  local review_iteration="$2"

  local template
  template=$(cat "$SCRIPT_DIR/codex-followup-context.md")

  local prior_verdict prior_confidence prior_explanation prior_findings
  prior_verdict=$(echo "$prior_review_json" | jq -r '.output.overall_correctness // ""')
  prior_confidence=$(echo "$prior_review_json" | jq -r '.output.overall_confidence_score // 0')
  prior_explanation=$(echo "$prior_review_json" | jq -r '.output.overall_explanation // ""')
  prior_findings=$(echo "$prior_review_json" | jq -c '.output.findings // []')

  template="${template//\{\{REVIEW_ITERATION\}\}/$review_iteration}"
  template="${template//\{\{ITERATION_MODE\}\}/followup-after-fixes}"
  template="${template//\{\{PRIOR_VERDICT\}\}/$prior_verdict}"
  template="${template//\{\{PRIOR_CONFIDENCE\}\}/$prior_confidence}"
  template="${template//\{\{PRIOR_EXPLANATION\}\}/$prior_explanation}"
  template="${template//\{\{PRIOR_FINDINGS\}\}/$prior_findings}"
  template="${template//\{\{PRIOR_SHA\}\}/}"
  template="${template//\{\{DELTA_BLOCK\}\}/}"

  echo "$template"
}

# ─── Build Follow-up Context (v2 P4) ────────────────────────────────────────
# Renders the codex-followup-context.md (or claude-followup-context.md)
# template using v2 placeholders. The prior_review JSON is the structured
# object produced by gather_prior_review_v2 (or the v1 wrapped form when
# called from the v1 back-compat path; see arg conventions below).
#
# Args:
#   1. family            — codex | claude (selects the template file).
#   2. prior_review_json — gather_prior_review_v2 output (or "" for none).
#   3. review_iteration  — current iteration number (1-based).
#   4. iteration_mode    — initial | followup-after-fixes | delta-since-prior.
#   5. prior_sha         — v2 prior SHA (may be empty).
#   6. delta_summary     — pre-rendered delta markdown (may be empty).
build_followup_context_v2() {
  local family="$1"
  local prior_review_json="$2"
  local review_iteration="$3"
  local iteration_mode="$4"
  local prior_sha="$5"
  local delta_summary="${6:-}"

  if [[ "$iteration_mode" == "initial" ]]; then
    # No follow-up section in initial mode.
    echo ""
    return 0
  fi

  local template_file
  case "$family" in
    codex)  template_file="$SCRIPT_DIR/codex-followup-context.md" ;;
    claude) template_file="$SCRIPT_DIR/claude-followup-context.md" ;;
    *)
      echo "Error: build_followup_context_v2: unknown family '$family'" >&2
      return 1
      ;;
  esac

  if [[ ! -f "$template_file" ]]; then
    # Best-effort: fall back to the codex template.
    template_file="$SCRIPT_DIR/codex-followup-context.md"
  fi

  local template
  template=$(cat "$template_file")

  local prior_verdict="" prior_confidence="0" prior_explanation="" prior_findings="[]"
  if [[ -n "$prior_review_json" ]] && printf '%s' "$prior_review_json" | jq empty 2>/dev/null; then
    # Tolerate both shapes:
    #   - gather_prior_review_v2 output: {found, prior_sha, iteration, verdict, findings, raw_data}
    #   - v1 raw embed: {output: {overall_correctness, overall_confidence_score, ...}}
    if printf '%s' "$prior_review_json" | jq -e '.raw_data.output' >/dev/null 2>&1; then
      prior_verdict=$(printf '%s' "$prior_review_json" | jq -r '.raw_data.output.overall_correctness // ""')
      prior_confidence=$(printf '%s' "$prior_review_json" | jq -r '.raw_data.output.overall_confidence_score // 0')
      prior_explanation=$(printf '%s' "$prior_review_json" | jq -r '.raw_data.output.overall_explanation // ""')
      prior_findings=$(printf '%s' "$prior_review_json" | jq -c '.raw_data.output.findings // .findings // []')
    elif printf '%s' "$prior_review_json" | jq -e '.output' >/dev/null 2>&1; then
      prior_verdict=$(printf '%s' "$prior_review_json" | jq -r '.output.overall_correctness // ""')
      prior_confidence=$(printf '%s' "$prior_review_json" | jq -r '.output.overall_confidence_score // 0')
      prior_explanation=$(printf '%s' "$prior_review_json" | jq -r '.output.overall_explanation // ""')
      prior_findings=$(printf '%s' "$prior_review_json" | jq -c '.output.findings // []')
    else
      prior_verdict=$(printf '%s' "$prior_review_json" | jq -r '.verdict // ""')
      prior_findings=$(printf '%s' "$prior_review_json" | jq -c '.findings // []')
    fi
  fi

  local delta_block_section=""
  if [[ "$iteration_mode" == "delta-since-prior" ]]; then
    delta_block_section="You are reviewing only the commits since the last review (SHA \`${prior_sha}\`). The following prior findings are carried forward — assess whether each is resolved in the delta or still present."$'\n\n'
    if [[ -n "$delta_summary" ]]; then
      delta_block_section+="${delta_summary}"$'\n\n'
    fi
  fi

  # Substitute placeholders. We use perl for multi-line-safe substitution of
  # the JSON-shaped placeholders.
  REVIEW_ITERATION_VAL="$review_iteration" \
  ITERATION_MODE_VAL="$iteration_mode" \
  PRIOR_VERDICT_VAL="$prior_verdict" \
  PRIOR_CONFIDENCE_VAL="$prior_confidence" \
  PRIOR_EXPLANATION_VAL="$prior_explanation" \
  PRIOR_FINDINGS_VAL="$prior_findings" \
  PRIOR_SHA_VAL="$prior_sha" \
  DELTA_BLOCK_VAL="$delta_block_section" \
  perl -pe '
    BEGIN {
      $ri  = $ENV{REVIEW_ITERATION_VAL};
      $im  = $ENV{ITERATION_MODE_VAL};
      $pv  = $ENV{PRIOR_VERDICT_VAL};
      $pc  = $ENV{PRIOR_CONFIDENCE_VAL};
      $pe  = $ENV{PRIOR_EXPLANATION_VAL};
      $pf  = $ENV{PRIOR_FINDINGS_VAL};
      $ps  = $ENV{PRIOR_SHA_VAL};
      $db  = $ENV{DELTA_BLOCK_VAL};
    }
    s/\Q{{REVIEW_ITERATION}}\E/$ri/g;
    s/\Q{{ITERATION_MODE}}\E/$im/g;
    s/\Q{{PRIOR_VERDICT}}\E/$pv/g;
    s/\Q{{PRIOR_CONFIDENCE}}\E/$pc/g;
    s/\Q{{PRIOR_EXPLANATION}}\E/$pe/g;
    s/\Q{{PRIOR_FINDINGS}}\E/$pf/g;
    s/\Q{{PRIOR_SHA}}\E/$ps/g;
    s/\Q{{DELTA_BLOCK}}\E/$db/g;
  ' <<< "$template"
}

# Render a markdown bullet list of prior findings for use in the delta block.
# Each finding renders as `[priority]` plus location, suitable for splicing
# into build_followup_context_v2's delta_summary arg.
render_prior_findings_summary() {
  local prior_review_json="$1"
  if [[ -z "$prior_review_json" ]]; then
    echo "_No prior findings._"
    return 0
  fi
  printf '%s' "$prior_review_json" | jq -r '
    (.findings // (.raw_data.output.findings // [])) as $fs
    | if ($fs | length) == 0 then
        "_No prior findings._"
      else
        ($fs | map(
          "- [P\(.priority // 0)] `\(.code_location.path // "?"):\(.code_location.start_line // 0)` — \(.title // "(no title)") `[persisting]`"
        ) | join("\n"))
      end
  ' 2>/dev/null || echo "_No prior findings._"
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
    head -n "$((line_num - 1))" "$WORK_DIR/_synthesis_template.md" > "$WORK_DIR/_synthesis_pre_det.md"
    cat "$chunk_results_file" >> "$WORK_DIR/_synthesis_pre_det.md"
    tail -n "+$((line_num + 1))" "$WORK_DIR/_synthesis_template.md" >> "$WORK_DIR/_synthesis_pre_det.md"
  else
    cp "$WORK_DIR/_synthesis_template.md" "$WORK_DIR/_synthesis_pre_det.md"
  fi

  # Splice deterministic findings at {{DET_FINDINGS}} (P3). Empty array → "[]"
  # so the model still sees the surrounding fenced JSON block consistently.
  local det_line_num det_findings_text="[]"
  if [[ -f "$WORK_DIR/det-findings.json" ]] && jq empty "$WORK_DIR/det-findings.json" 2>/dev/null; then
    det_findings_text=$(jq '.' "$WORK_DIR/det-findings.json" 2>/dev/null || echo "[]")
  fi
  det_line_num=$(grep -n '{{DET_FINDINGS}}' "$WORK_DIR/_synthesis_pre_det.md" | head -1 | cut -d: -f1)
  if [[ -n "$det_line_num" ]]; then
    head -n "$((det_line_num - 1))" "$WORK_DIR/_synthesis_pre_det.md" > "$WORK_DIR/_synthesis_pre_diff.md"
    printf '%s\n' "$det_findings_text" >> "$WORK_DIR/_synthesis_pre_diff.md"
    tail -n "+$((det_line_num + 1))" "$WORK_DIR/_synthesis_pre_det.md" >> "$WORK_DIR/_synthesis_pre_diff.md"
  else
    cp "$WORK_DIR/_synthesis_pre_det.md" "$WORK_DIR/_synthesis_pre_diff.md"
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

  # If chunking produced only 1 chunk AND v2 dual-family is unavailable, fall
  # back to single review (Codex-only). When v2 is available the chunked path
  # works fine with 1 chunk and gives us the full dual-family + verifier flow,
  # which is the headline anti-hallucination feature. v1 fallback is the
  # graceful-degradation path when claude CLI is missing or --no-verify is set.
  if [[ "$total_chunks" -eq 1 ]] && ! v2_dual_family_enabled; then
    echo "Only 1 chunk produced and v2 dual-family unavailable; using single review path." >&2
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

  if [[ ${#batch_pids[@]} -gt 0 ]]; then
    for p in "${batch_pids[@]}"; do
      wait "$p" || true
    done
  fi

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

  # ─── Drain deterministic floor and merge into synthesis input (P3) ────────
  # det-floor.sh runs in parallel with the LLM fan-out. Wait for it now (it is
  # almost certainly already done). Merge its findings into merged-findings.json
  # so synthesis sees the full picture: pre-verified LLM findings plus the
  # tool-grounded deterministic findings. Dedup on finding_id (file|start|title)
  # to avoid double-counting if a deterministic finding happens to match an LLM
  # finding's location and title verbatim. Deterministic wins on dedup.
  if [[ -n "${DET_FLOOR_PID:-}" ]]; then
    wait "$DET_FLOOR_PID" 2>/dev/null || true
  fi
  local det_file="$WORK_DIR/det-findings.json"
  if [[ -f "$det_file" ]] && jq empty "$det_file" 2>/dev/null; then
    local det_count
    det_count=$(jq 'length' "$det_file")
    if [[ "$det_count" -gt 0 ]]; then
      echo "Merging $det_count deterministic findings into synthesis input..." >&2
      local combined_file="$WORK_DIR/merged-findings-with-det.json"
      jq -s '
        def keyof(f): (f.code_location.path // "") + "|" + ((f.code_location.start_line // 0)|tostring) + "|" + (f.title // "");
        # .[0] = LLM merged-findings, .[1] = deterministic findings.
        # Deterministic findings come first (so they sort above LLM at equal
        # priority in format_comment); dedup keeps the deterministic version
        # when both an LLM and a deterministic finding share the same key.
        (.[1] + .[0])
        | unique_by(keyof(.))
      ' "$merged_file" "$det_file" > "$combined_file"
      mv "$combined_file" "$merged_file"
    fi
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
        # P3 guard: if a chunk output somehow contains a `source: deterministic`
        # finding, skip verification — deterministic findings are grounded in
        # tool exit codes, not LLM inference, and re-verifying them would just
        # waste a verifier slot. They're spliced back in post-verifier from
        # det-findings.json, so dropping them here is safe.
        local existing_source
        existing_source=$(printf '%s' "$finding" | jq -r '.source // ""')
        if [[ "$existing_source" == "deterministic" ]]; then
          continue
        fi
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
  # Guard empty-array drain: macOS bash 3.2 + set -u treats ${pids[@]} on an
  # empty array as unbound. Fires when the chunk reviewers produced 0 findings.
  if [[ ${#pids[@]} -gt 0 ]]; then
    for p in "${pids[@]}"; do
      wait "$p" || true
    done
  fi

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

# ─── Merge deterministic findings into final output (v2 P3) ─────────────────
# Run from main() after the LLM pipeline finishes (single or chunked) and
# before format_comment. Reads $det_file (a JSON array conforming to
# det-output-schema.json), reads $output_file (the synthesis or single-review
# output, conforming to codex-output-schema.json), and writes back to
# $output_file with deterministic findings appended to .findings[]. Dedups on
# (file|start_line|title); deterministic wins. No-op if det_file is missing or
# empty.
#
# In the chunked path, deterministic findings are *also* fed into the synthesis
# input (via merged-findings.json). This second merge here exists so the
# single-review path (which has no synthesis) and any synthesis output that
# accidentally drops deterministic findings still surface them in the final
# PR comment.
merge_det_into_output() {
  local output_file="$1"
  local det_file="$2"

  [[ -f "$output_file" ]] || return 0
  [[ -f "$det_file" ]] || return 0
  jq empty "$output_file" 2>/dev/null || return 0
  jq empty "$det_file" 2>/dev/null || return 0

  local det_count
  det_count=$(jq 'length' "$det_file" 2>/dev/null || echo 0)
  if [[ "$det_count" -eq 0 ]]; then
    return 0
  fi

  # The codex-output-schema requires `status` on every finding; deterministic
  # findings produced by det-floor.sh do not have it (det-output-schema.json
  # does not include status). Inject status="new" during the merge.
  local merged_tmp="$WORK_DIR/_codex-output-merged.json"
  jq --slurpfile det "$det_file" '
    def keyof(f): (f.code_location.path // "") + "|" + ((f.code_location.start_line // 0)|tostring) + "|" + (f.title // "");
    . as $root
    | ($det[0] | map(. + {status: "new"})) as $detF
    | ($detF + ($root.findings // [])) as $combined
    | $combined | unique_by(keyof(.)) as $deduped
    | $root | .findings = $deduped
  ' "$output_file" > "$merged_tmp" 2>/dev/null || return 0

  if jq empty "$merged_tmp" 2>/dev/null; then
    mv "$merged_tmp" "$output_file"
    echo "Merged $det_count deterministic finding(s) into $(basename "$output_file")." >&2
  fi
}

# ─── Format Comment (v2 P5 spec §4.7 layout) ─────────────────────────────────
# Renders a PR comment per spec §4.7:
#   ## Codex PR Review v2 — Iteration N (mode)
#   **Verdict:** <v2 enum> (confidence X)
#   ### Resolved since last review (N)            (only when mode != initial)
#   ### Findings (N)
#     #### [agreement-badges] [Pn] file:line — title
#     > body
#     >
#     > **Suggested fix:** ...
#   ### Persisting from prior review (N)          (only when mode != initial)
#   ---
#   <!-- codex-pr-review:meta v=2 ... -->         (P4 sentinel preserved)
#   <!-- CODEX_REVIEW_DATA_START ... END -->      (v1 rollback preserved)
#
# Compatibility shim: v1 verdict strings are mapped to the v2 enum BEFORE
# rendering so a v1 Codex output flowing through v2 format_comment (e.g.,
# during a `--no-verify` debug run) produces sensible output.
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

  # v1 → v2 verdict shim. Required so a v1-shaped synthesis output flowing
  # through v2 format_comment renders the v2 enum verbatim. Spec §11.
  verdict=$(echo "$verdict" | sed 's/patch is correct/correct/; s/patch is incorrect/needs-changes/')

  # ── Iteration metadata (v2 P4) ───────────────────────────────────────────
  local iter_meta_file="$WORK_DIR/iteration-meta.json"
  local iter_mode="initial" iter_prior_sha=""
  if [[ -f "$iter_meta_file" ]] && jq empty "$iter_meta_file" 2>/dev/null; then
    iter_mode=$(jq -r '.mode // "initial"' "$iter_meta_file")
    iter_prior_sha=$(jq -r '.prior_sha // ""' "$iter_meta_file")
  fi

  local iter_label_human="initial"
  case "$iter_mode" in
    initial)               iter_label_human="initial" ;;
    followup-after-fixes)  iter_label_human="follow-up" ;;
    delta-since-prior)     iter_label_human="delta" ;;
    *)                     iter_label_human="$iter_mode" ;;
  esac

  # ── Header + Verdict ─────────────────────────────────────────────────────
  local comment=""
  comment+="## Codex PR Review v2 — Iteration $review_iteration ($iter_label_human)"$'\n\n'
  comment+="**Verdict:** $verdict (confidence $confidence_score)"$'\n\n'
  if [[ -n "$explanation" && "$explanation" != "null" ]]; then
    comment+="$explanation"$'\n\n'
  fi

  # ── Resolved since last review (mode != initial) ─────────────────────────
  if [[ "$iter_mode" != "initial" ]]; then
    local resolved_buf="$WORK_DIR/_resolved_titles.json"
    : > "$resolved_buf"
    # Prefer top-level delta.resolved (P5 schema), then iteration_meta.delta.resolved
    # (P4 schema), then resolved_prior_findings (v1 carry-over).
    if jq -e '.delta.resolved // empty | length > 0' "$output_file" >/dev/null 2>&1; then
      jq -c '.delta.resolved[]?' "$output_file" >> "$resolved_buf" 2>/dev/null || true
    elif jq -e '.iteration_meta.delta.resolved // empty | length > 0' "$output_file" >/dev/null 2>&1; then
      jq -c '.iteration_meta.delta.resolved[]?' "$output_file" >> "$resolved_buf" 2>/dev/null || true
    elif jq -e '(.resolved_prior_findings // []) | length > 0' "$output_file" >/dev/null 2>&1; then
      jq -c '.resolved_prior_findings[]?' "$output_file" >> "$resolved_buf" 2>/dev/null || true
    fi
    local resolved_count
    resolved_count=$(wc -l < "$resolved_buf" | tr -d ' ')
    if [[ "$resolved_count" -gt 0 ]]; then
      comment+="### Resolved since last review ($resolved_count)"$'\n\n'
      while IFS= read -r entry; do
        [[ -z "$entry" ]] && continue
        local line
        line=$(printf '%s' "$entry" | jq -r '
          if type == "string" then
            "- ~~" + . + "~~"
          elif type == "object" then
            "- ~~`\(.code_location.path // "?"):\(.code_location.start_line // 0)` — \(.title // "(no title)")~~"
          else
            "- ~~" + tostring + "~~"
          end
        ' 2>/dev/null || echo "- ~~${entry}~~")
        comment+="${line}"$'\n'
      done < "$resolved_buf"
      comment+=$'\n'
    fi
  fi

  # ── Findings (N) — fenced sub-block per finding ──────────────────────────
  if [[ "$filtered_count" -eq 0 ]]; then
    comment+="### Findings (0)"$'\n\n'
    comment+="No findings above confidence threshold ($THRESHOLD)."$'\n\n'
  else
    comment+="### Findings ($filtered_count)"$'\n\n'

    while IFS= read -r finding; do
      local title body priority path start_line end_line status agreement source verifier_verdict suggested_fix
      title=$(echo "$finding" | jq -r '.title // ""')
      body=$(echo "$finding" | jq -r '.body // ""')
      priority=$(echo "$finding" | jq -r '.priority // 0')
      path=$(echo "$finding" | jq -r '.code_location.path // "?"')
      start_line=$(echo "$finding" | jq -r '.code_location.start_line // 0')
      end_line=$(echo "$finding" | jq -r '.code_location.end_line // 0')
      status=$(echo "$finding" | jq -r '.status // "new"')
      agreement=$(echo "$finding" | jq -r '.agreement // ""')
      source=$(echo "$finding" | jq -r '.source // ""')
      verifier_verdict=$(echo "$finding" | jq -r '.verifier_verdict // ""')
      suggested_fix=$(echo "$finding" | jq -r '.suggested_fix // ""')

      # Agreement badges. Multiple badges are allowed but the verifier flow
      # only ever produces one of these per finding in practice.
      local badges=""
      case "$agreement" in
        both)                  badges="[both]" ;;
        codex-only)            badges="[codex-only]" ;;
        claude-only)           badges="[claude-only]" ;;
        unconfirmed-by-codex)  badges="[unconfirmed-by-codex]" ;;
        unconfirmed-by-claude) badges="[unconfirmed-by-claude]" ;;
        deterministic)         badges="[deterministic]" ;;
        "")                    badges="" ;;
        *)                     badges="[${agreement}]" ;;
      esac
      # Add [deterministic] alongside the agreement badge if source says so
      # but the agreement label didn't (defensive — synthesizer should set
      # agreement=deterministic for source=deterministic).
      if [[ "$source" == "deterministic" && "$badges" != *"[deterministic]"* ]]; then
        if [[ -n "$badges" ]]; then
          badges="$badges [deterministic]"
        else
          badges="[deterministic]"
        fi
      fi

      local location="${path}:${start_line}"
      if [[ "$start_line" != "$end_line" && "$end_line" != "0" ]]; then
        location="${path}:${start_line}-${end_line}"
      fi

      # Header: #### [badges] [Pn] file:line — title
      local header="#### "
      if [[ -n "$badges" ]]; then
        header+="$badges "
      fi
      header+="[P${priority}] \`${location}\` — ${title}"
      if [[ "$review_iteration" -gt 1 && "$status" == "persisting" ]]; then
        header+=" [PERSISTING]"
      fi
      comment+="${header}"$'\n'

      # Body block (each line prefixed with `> ` so it renders as a quote
      # in GitHub markdown).
      local body_quoted
      body_quoted=$(printf '%s' "$body" | sed 's/^/> /')
      comment+="${body_quoted}"$'\n'
      comment+=">"$'\n'
      if [[ -n "$suggested_fix" && "$suggested_fix" != "null" ]]; then
        comment+="> **Suggested fix:** ${suggested_fix}"$'\n'
      else
        comment+="> **Suggested fix:** (none provided)"$'\n'
      fi
      comment+=$'\n'
    done < <(jq -c --arg t "$THRESHOLD" '
      # P3 sort order preserved: priority desc → deterministic first within
      # each priority bucket → title alphabetical (stable tiebreaker).
      [.findings[] | select(.confidence_score >= ($t | tonumber))]
      | sort_by([
          -((.priority // 0)),
          (if (.source // "") == "deterministic" then 0 else 1 end),
          (.title // "")
        ])
      | .[]
    ' "$output_file")
  fi

  # ── Persisting from prior review (mode != initial) ───────────────────────
  if [[ "$iter_mode" != "initial" ]]; then
    local persisting_buf="$WORK_DIR/_persisting_titles.json"
    : > "$persisting_buf"
    if jq -e '.delta.persisting // empty | length > 0' "$output_file" >/dev/null 2>&1; then
      jq -c '.delta.persisting[]?' "$output_file" >> "$persisting_buf" 2>/dev/null || true
    elif jq -e '.iteration_meta.delta.persisting // empty | length > 0' "$output_file" >/dev/null 2>&1; then
      jq -c '.iteration_meta.delta.persisting[]?' "$output_file" >> "$persisting_buf" 2>/dev/null || true
    fi
    local persisting_count
    persisting_count=$(wc -l < "$persisting_buf" | tr -d ' ')
    if [[ "$persisting_count" -gt 0 ]]; then
      comment+="### Persisting from prior review ($persisting_count)"$'\n\n'
      while IFS= read -r entry; do
        [[ -z "$entry" ]] && continue
        local rendered
        rendered=$(printf '%s' "$entry" | jq -r '
          if type == "string" then
            "- [persisting] " + . + " — same issue, not addressed."
          elif type == "object" then
            "- [persisting] [P\(.priority // 0)] `\(.code_location.path // "?"):\(.code_location.start_line // 0)` — \(.title // "(no title)") — same issue, not addressed."
          else
            "- [persisting] " + tostring
          end
        ' 2>/dev/null || echo "- [persisting] $entry")
        comment+="${rendered}"$'\n'
      done < "$persisting_buf"
      comment+=$'\n'
    fi
  fi

  comment+="---"$'\n'

  # Warn about incomplete coverage if any chunks failed during chunked review.
  if [[ -f "$WORK_DIR/chunk-stats.txt" ]]; then
    local stats_succeeded stats_failed
    stats_succeeded=$(sed -n '1p' "$WORK_DIR/chunk-stats.txt")
    stats_failed=$(sed -n '2p' "$WORK_DIR/chunk-stats.txt")
    if [[ "$stats_failed" -gt 0 ]]; then
      local total_c=$((stats_succeeded + stats_failed))
      comment+=$'\n'"> ⚠️ **Incomplete coverage:** ${stats_failed} of ${total_c} chunks failed during review. Findings reflect only the ${stats_succeeded} successful chunks. Consider retrying or reducing \`--max-parallel\`."$'\n'
    fi
  fi

  local iteration_label=""
  if [[ "$review_iteration" -gt 1 ]]; then
    iteration_label=" | Follow-up #$review_iteration"
  fi
  comment+=$'\n'"*Reviewed by codex-pr-review v2 (codex=$MODEL_CODEX, claude=$MODEL_CLAUDE)${iteration_label} | Threshold: $THRESHOLD | $total_findings total findings, $filtered_count reported*"

  # ── v2 sentinel (compact, machine-parseable; primary in v2) ──────────────
  comment+=$'\n\n'"<!-- codex-pr-review:meta v=2 sha=${head_sha} iteration=${review_iteration} findings=${filtered_count} verdict=${verdict} mode=${iter_mode} prior_sha=${iter_prior_sha} -->"

  # ── Legacy CODEX_REVIEW_DATA_START block (v1 rollback). Preserved per spec
  # §11; allows a v2→v1 downgrade to keep the iteration counter.
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

  # ── Prior review detection + iteration classification (v2 P4) ─────────────
  echo "Checking for prior Codex/Claude reviews..." >&2
  local review_iteration=1 followup_context=""
  local prior_review_v2_json="" prior_found="false" prior_sha="" prior_iteration=0
  local iteration_mode="initial"

  if prior_review_v2_json=$(gather_prior_review_v2 "$pr_number" 2>/dev/null) \
       && [[ -n "$prior_review_v2_json" ]] \
       && printf '%s' "$prior_review_v2_json" | jq -e '.found' >/dev/null 2>&1; then
    prior_found="true"
    prior_sha=$(printf '%s' "$prior_review_v2_json" | jq -r '.prior_sha // ""')
    prior_iteration=$(printf '%s' "$prior_review_v2_json" | jq -r '.iteration // 0')
    review_iteration=$((prior_iteration + 1))
    echo "  Found prior review (iteration $prior_iteration, prior_sha=${prior_sha:-<none>}). This will be follow-up review #$review_iteration." >&2
  else
    echo "  No prior Codex reviews found." >&2
  fi

  # Classify the iteration mode honoring --mode override.
  if ! iteration_mode=$(classify_iteration "$prior_sha" "$prior_found" "$MODE"); then
    # classify_iteration writes its own error to stderr (e.g., --mode delta
    # without a prior review); propagate hard fail.
    exit 2
  fi
  echo "  Iteration mode: $iteration_mode" >&2

  # If --mode initial overrides a prior, reset state so we don't load the
  # prior context into the prompt.
  if [[ "$iteration_mode" == "initial" ]]; then
    prior_review_v2_json=""
    prior_found="false"
    prior_sha=""
    review_iteration=1
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

  # ── Delta diff for delta-since-prior mode (v2 P4) ─────────────────────────
  # When the iteration classifier has decided we should review only the
  # commits since the prior review SHA, swap the diff_file pointer to the
  # delta diff. On failure (shallow clone), fall back to the full PR diff
  # AND demote the iteration mode to followup-after-fixes.
  if [[ "$iteration_mode" == "delta-since-prior" && -n "$prior_sha" ]]; then
    local delta_diff_file="$WORK_DIR/delta-diff.txt"
    if compute_delta_diff "$prior_sha" "$delta_diff_file" \
         && [[ -s "$delta_diff_file" ]]; then
      echo "  Using delta diff (commits since $prior_sha)." >&2
      diff_file="$delta_diff_file"
    else
      echo "  Falling back to full PR diff and downgrading to followup-after-fixes." >&2
      iteration_mode="followup-after-fixes"
    fi
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

  # Build the v2 follow-up context now that we know the iteration mode and
  # the (possibly delta-substituted) diff_file. The codex prompt builder picks
  # this up via {{PRIOR_REVIEW}}; the claude prompt builder uses the same
  # variable. A single context body is shared across both families to keep
  # the prior-finding wording consistent.
  if [[ "$iteration_mode" != "initial" && "$prior_found" == "true" ]]; then
    local delta_summary=""
    if [[ "$iteration_mode" == "delta-since-prior" ]]; then
      delta_summary=$(render_prior_findings_summary "$prior_review_v2_json")
    fi
    followup_context=$(build_followup_context_v2 \
      "codex" \
      "$prior_review_v2_json" \
      "$review_iteration" \
      "$iteration_mode" \
      "$prior_sha" \
      "$delta_summary")
  else
    followup_context=""
  fi

  # Persist iteration metadata for synthesis and format_comment.
  local iteration_meta_file="$WORK_DIR/iteration-meta.json"
  jq -n \
    --argjson iteration "$review_iteration" \
    --arg mode "$iteration_mode" \
    --arg prior_sha "$prior_sha" \
    --argjson prior_findings "$(printf '%s' "${prior_review_v2_json:-{}}" | jq -c '.findings // []' 2>/dev/null || echo '[]')" \
    '{
      iteration: $iteration,
      mode: $mode,
      prior_sha: $prior_sha,
      prior_findings: $prior_findings
    }' > "$iteration_meta_file" 2>/dev/null || \
      printf '{"iteration":%s,"mode":"%s","prior_sha":"%s","prior_findings":[]}\n' \
        "$review_iteration" "$iteration_mode" "$prior_sha" > "$iteration_meta_file"

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

  # ─── Launch deterministic floor (P3) ──────────────────────────────────────
  # det-floor.sh runs lint/typecheck/tests on the diff-touched lines and writes
  # $WORK_DIR/det-findings.json. It runs in parallel with the LLM fan-out so it
  # does not sit on the critical path. We drain it before synthesis (chunked
  # path inside run_chunked_review) and again before format_comment (covers
  # the single-review path which has no synthesis). The output schema matches
  # the v2 finding shape; merge_det_into_output() splices results into
  # codex-output.json so format_comment renders them with the [deterministic]
  # badge.
  local det_repo_root
  det_repo_root=$(git rev-parse --show-toplevel 2>/dev/null || echo "$PWD")
  local det_pid=""
  if [[ -x "$SCRIPT_DIR/det-floor.sh" ]]; then
    NO_DETERMINISTIC="$NO_DETERMINISTIC" \
      bash "$SCRIPT_DIR/det-floor.sh" "$WORK_DIR" "$det_repo_root" "$diff_file" \
      >>"$WORK_DIR/det-floor-stdout.log" 2>>"$WORK_DIR/det-floor-stderr-launcher.log" &
    det_pid=$!
    DET_FLOOR_PID="$det_pid"
    export DET_FLOOR_PID
  else
    echo "Note: det-floor.sh not found at $SCRIPT_DIR/det-floor.sh; skipping deterministic floor." >&2
    printf '[]' > "$WORK_DIR/det-findings.json"
  fi

  # Route: chunked path is the v2 default — it gives the full dual-family
  # (Codex + Claude) review and cross-family verifier, even on 1-chunk diffs.
  # The v1 single-review path stays as a graceful-degradation fallback when
  # v2 dual-family is unavailable (claude CLI missing, or --no-verify).
  if v2_dual_family_enabled; then
    if [[ "$diff_lines" -le "$CHUNK_SIZE" ]]; then
      echo "Diff is $diff_lines lines; using v2 dual-family review (Codex + Claude in parallel)." >&2
    else
      echo "Diff is $diff_lines lines (exceeds chunk size $CHUNK_SIZE); using v2 dual-family chunked review." >&2
    fi
    run_chunked_review "$pr_number" "$pr_title" "$head_branch" "$base_branch" "$diff_file" "$project_rules" "$followup_context" "$manifest_file"
  elif [[ "$diff_lines" -le "$CHUNK_SIZE" ]]; then
    echo "Diff is $diff_lines lines and v2 dual-family unavailable; using v1 single review (Codex-only)." >&2
    run_single_review "$pr_number" "$pr_title" "$head_branch" "$base_branch" "$diff_file" "$project_rules" "$followup_context" "$manifest_file"
  else
    echo "Diff is $diff_lines lines and v2 dual-family unavailable; using v1 chunked review (Codex-only fan-out)." >&2
    run_chunked_review "$pr_number" "$pr_title" "$head_branch" "$base_branch" "$diff_file" "$project_rules" "$followup_context" "$manifest_file"
  fi

  # Drain the deterministic floor (it should be done long before now, but be
  # explicit). Then splice its findings into codex-output.json so format_comment
  # renders them with the [deterministic] badge. Failures here are non-fatal —
  # an empty det-findings.json yields a no-op merge.
  if [[ -n "$det_pid" ]]; then
    wait "$det_pid" 2>/dev/null || true
  fi
  merge_det_into_output "$WORK_DIR/codex-output.json" "$WORK_DIR/det-findings.json"

  # ─── Location validator (v2 P5) ───────────────────────────────────────────
  # Deterministic post-synthesis filter: drops findings whose code_location
  # does not resolve into the diff (file missing, line outside hunks),
  # findings with empty body, missing confidence_score, or confidence_score
  # below THRESHOLD. The maintainability category is exempted from the
  # outside-hunks check (some maintainability findings legitimately point at
  # unchanged-but-related lines in touched files).
  if [[ -x "$SCRIPT_DIR/location-validator.sh" ]] && [[ -f "$WORK_DIR/codex-output.json" ]]; then
    local validated_file="$WORK_DIR/codex-output-validated.json"
    if THRESHOLD="$THRESHOLD" bash "$SCRIPT_DIR/location-validator.sh" \
        "$WORK_DIR/codex-output.json" "$diff_file" "$validated_file" \
        2>>"$WORK_DIR/location-validator.log"; then
      # Surface the validator's stderr summary on the user's terminal too.
      if [[ -s "$WORK_DIR/location-validator.log" ]]; then
        sed -e 's/^/  /' "$WORK_DIR/location-validator.log" >&2 || true
      fi
      if [[ -s "$validated_file" ]] && jq empty "$validated_file" 2>/dev/null; then
        mv "$validated_file" "$WORK_DIR/codex-output.json"
      else
        echo "Note: location-validator.sh produced an unusable output; keeping pre-validation findings." >&2
      fi
    else
      echo "Note: location-validator.sh failed; keeping pre-validation findings." >&2
      [[ -s "$WORK_DIR/location-validator.log" ]] && \
        sed -e 's/^/  /' "$WORK_DIR/location-validator.log" >&2 || true
    fi
  fi

  # Format and post (same for both paths — both produce codex-output.json)
  echo "Formatting results..." >&2
  local comment
  comment=$(format_comment "$WORK_DIR/codex-output.json" "$pr_url" "$review_iteration" "$head_sha")

  echo "$comment" > "$WORK_DIR/pr-comment.md"
  if [[ "$DRY_RUN" == "true" ]]; then
    local dry_run_path="/tmp/codex-pr-review-dry-run-pr${pr_number}-$(date -u +%Y%m%dT%H%M%SZ).md"
    cp "$WORK_DIR/pr-comment.md" "$dry_run_path"
    echo "Dry-run: rendered review NOT posted to PR #$pr_number." >&2
    echo "Dry-run: comment body saved to $dry_run_path" >&2
    echo "--- Review output (dry-run, not posted) ---"
    echo "$comment"
  else
    echo "Posting review to PR #$pr_number..." >&2
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
  fi

  # Output summary JSON for Claude to parse (v2: adds verdict mapped to v2
  # enum, agreement_summary counts, and a delta block on follow-up runs).
  local filtered_count total_findings resolved_count raw_verdict v2_verdict
  total_findings=$(jq '.findings | length' "$WORK_DIR/codex-output.json")
  filtered_count=$(jq --arg t "$THRESHOLD" '[.findings[] | select(.confidence_score >= ($t | tonumber))] | length' "$WORK_DIR/codex-output.json")
  resolved_count=$(jq '[.resolved_prior_findings // [] | length] | .[0]' "$WORK_DIR/codex-output.json")
  raw_verdict=$(jq -r '.overall_correctness' "$WORK_DIR/codex-output.json")
  # Same v1→v2 verdict shim format_comment uses (kept consistent).
  v2_verdict=$(echo "$raw_verdict" | sed 's/patch is correct/correct/; s/patch is incorrect/needs-changes/')

  # Agreement summary: count how many findings carry each agreement label.
  local agreement_summary
  agreement_summary=$(jq --arg t "$THRESHOLD" '
    [.findings[] | select(.confidence_score >= ($t | tonumber))] as $f
    | {
        both:                  ($f | map(select(.agreement == "both"))                  | length),
        codex_only:            ($f | map(select(.agreement == "codex-only"))            | length),
        claude_only:           ($f | map(select(.agreement == "claude-only"))           | length),
        deterministic:         ($f | map(select(.agreement == "deterministic"))         | length),
        unconfirmed_by_codex:  ($f | map(select(.agreement == "unconfirmed-by-codex"))  | length),
        unconfirmed_by_claude: ($f | map(select(.agreement == "unconfirmed-by-claude")) | length)
      }
  ' "$WORK_DIR/codex-output.json" 2>/dev/null || echo '{"both":0,"codex_only":0,"claude_only":0,"deterministic":0,"unconfirmed_by_codex":0,"unconfirmed_by_claude":0}')

  # Delta block: only when iteration mode != initial.
  local delta_block='null'
  if [[ "$iteration_mode" != "initial" ]]; then
    delta_block=$(jq '
      (.delta // .iteration_meta.delta // null)
    ' "$WORK_DIR/codex-output.json" 2>/dev/null || echo 'null')
  fi

  jq -n \
    --arg pr_url "$pr_url" \
    --arg pr_number "$pr_number" \
    --arg verdict "$v2_verdict" \
    --arg verdict_raw "$raw_verdict" \
    --arg confidence "$(jq -r '.overall_confidence_score' "$WORK_DIR/codex-output.json")" \
    --arg explanation "$(jq -r '.overall_explanation' "$WORK_DIR/codex-output.json")" \
    --argjson total "$total_findings" \
    --argjson reported "$filtered_count" \
    --argjson resolved "$resolved_count" \
    --argjson iteration "$review_iteration" \
    --arg mode "$iteration_mode" \
    --arg threshold "$THRESHOLD" \
    --arg model "$MODEL" \
    --argjson agreement_summary "$agreement_summary" \
    --argjson delta "$delta_block" \
    '{
      status: "success",
      pr_url: $pr_url,
      pr_number: $pr_number,
      model: $model,
      threshold: $threshold,
      review_iteration: $iteration,
      mode: $mode,
      verdict: $verdict,
      verdict_raw: $verdict_raw,
      overall_confidence: $confidence,
      explanation: $explanation,
      total_findings: $total,
      reported_findings: $reported,
      resolved_findings: $resolved,
      agreement_summary: $agreement_summary,
      delta: $delta
    }'

  if [[ "$DRY_RUN" == "true" ]]; then
    echo "Dry-run complete (no comment posted to $pr_url)." >&2
  else
    echo "Review posted to $pr_url" >&2
  fi
}

main
