---
name: codex-pr-review
description: Review a pull request using OpenAI Codex (gpt-5.3-codex). Use when the user wants an external AI code review via Codex, a second opinion on a PR, or a cross-model review. Supports auto-detection of current branch PR or explicit PR number/URL.
license: MIT
metadata:
  author: sasser
  version: 0.3.0
allowed-tools: Bash
argument-hint: "[PR_NUMBER|PR_URL] [--threshold FLOAT] [--model MODEL] [--chunk-size INT] [--max-diff-lines INT]"
---

# Codex PR Review

Review a pull request using OpenAI Codex for an independent, cross-model code review.

## Prerequisites

- `codex` CLI installed and on PATH
- `codex` authenticated via OAuth (`codex login`) — headless mode (`codex exec`) requires OAuth, not an API key
- `gh` CLI installed and authenticated
- Current directory must be a git repository

## Usage

```
/codex-pr-review                          # Auto-detect PR for current branch
/codex-pr-review 123                      # Review PR #123
/codex-pr-review --threshold 0.6          # Lower confidence threshold
/codex-pr-review 123 --model gpt-5.2-codex  # Use a specific model
/codex-pr-review --max-diff-lines 25000     # Increase diff safety limit
/codex-pr-review --chunk-size 5000           # Smaller chunks for faster parallel reviews
/codex-pr-review --chunk-size 50 123         # Force chunking (useful for testing)
```

## Arguments

| Argument | Default | Description |
|----------|---------|-------------|
| `PR_NUMBER` or `PR_URL` | auto-detect | PR to review. If omitted, detects from current branch |
| `--threshold` | `0.8` | Minimum confidence score (0-1) for reporting findings |
| `--model` | `gpt-5.3-codex` | Codex model to use |
| `--chunk-size` | `5000` | Lines per chunk. Diffs exceeding this are split and reviewed in parallel |
| `--max-diff-lines` | `200000` | Safety limit — diffs beyond this are truncated |

## Large PR Support

PRs with diffs exceeding the chunk size (default 5,000 lines) are automatically split into chunks and reviewed in parallel:

1. The diff is split along file and hunk boundaries (never mid-hunk) using an AWK script
2. Each chunk is reviewed independently by a separate `codex exec` instance, running in parallel
3. All chunk results are synthesized into a single coherent review that deduplicates findings and detects cross-chunk patterns
4. The final output uses the same format as a single-chunk review

This allows reviewing PRs of 100K+ lines without truncation. Use `--chunk-size` to tune the chunk size (smaller = more parallelism but more synthesis overhead).

## Follow-up Review Detection

When a PR has been reviewed before, subsequent reviews automatically detect prior findings and operate as follow-up reviews:

1. Prior Codex review comments are detected via embedded metadata in PR comments
2. The reviewer receives the full context of prior findings (verdict, confidence, all findings)
3. The follow-up review assesses which prior findings have been resolved and which persist
4. New issues introduced by fix commits are flagged alongside persisting issues
5. The PR comment shows resolved findings (struck through), persisting findings (labeled `[PERSISTING]`), and the review iteration number

This is fully automatic — just run `/codex-pr-review` again after pushing fixes. The review will reference the most recent prior Codex review.

The summary JSON output includes additional fields for follow-up reviews:
- `review_iteration`: which review iteration this is (1 = initial, 2+ = follow-up)
- `resolved_findings`: count of prior findings that were resolved

## How to Execute This Skill

When this skill is invoked, run the review script:

```bash
bash $CLAUDE_PLUGIN_ROOT/scripts/review.sh [ARGS]
```

Where `[ARGS]` are the arguments the user passed after `/codex-pr-review`.

If `$CLAUDE_PLUGIN_ROOT` is not set, use the absolute path:

```bash
bash ~/.claude/skills/codex-pr-review/scripts/review.sh [ARGS]
```

### Interpreting Results

The script outputs JSON to stdout on success. Read the output and present it to the user as a formatted summary. If the script exits non-zero, display the error message to the user.

After the script succeeds, inform the user:
- How many findings were found vs. how many passed the threshold
- The overall correctness verdict and confidence
- That the review has been posted as a PR comment (with link)
- For follow-up reviews: the review iteration number, how many prior findings were resolved, and how many persist

### Error Handling

| Exit Code | Meaning |
|-----------|---------|
| 0 | Success - review posted |
| 1 | Missing prerequisite (codex, gh, or OAuth not configured) |
| 2 | PR not found or not detectable |
| 3 | Codex execution failed |
| 4 | Failed to post comment |
