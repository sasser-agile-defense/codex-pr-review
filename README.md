# Codex PR Review

A Claude Code skill that reviews pull requests using [OpenAI Codex](https://openai.com/index/introducing-codex/) for independent, cross-model code review. Get a second opinion on any PR without leaving Claude Code.

## What It Does

When you run `/codex-pr-review`, the skill:

1. Detects the PR from your current branch (or takes a PR number/URL)
2. Gathers the diff and any `CLAUDE.md` project rules
3. Sends everything to Codex with a structured review prompt
4. Posts the review as a PR comment with findings, confidence scores, and a verdict

Findings are filtered by a configurable confidence threshold (default 0.8) so you only see issues the model is genuinely certain about.

## Requirements

- [Claude Code](https://docs.anthropic.com/en/docs/claude-code) CLI installed
- [Codex CLI](https://github.com/openai/codex) installed (`npm install -g @openai/codex`)
- Codex authenticated via OAuth (`codex login`) -- headless mode requires OAuth, not an API key
- [GitHub CLI](https://cli.github.com/) (`gh`) installed and authenticated
- [jq](https://jqlang.github.io/jq/) installed

## Installation

```bash
git clone https://github.com/johnpsasser/codex-pr-review.git
cd codex-pr-review
./install.sh
```

Then restart Claude Code.

## Usage

```
/codex-pr-review                             # Auto-detect PR for current branch
/codex-pr-review 123                         # Review PR #123
/codex-pr-review https://github.com/.../42   # Review by URL
/codex-pr-review --threshold 0.6             # Lower confidence threshold
/codex-pr-review 123 --model gpt-5.2-codex   # Use a different model
/codex-pr-review --chunk-size 5000           # Larger chunks (fewer parallel calls)
/codex-pr-review --max-parallel 3            # Throttle concurrent Codex calls
/codex-pr-review --no-verify                 # Skip the verification pass
```

### Arguments

| Argument | Default | Description |
|----------|---------|-------------|
| `PR_NUMBER` or `PR_URL` | auto-detect | PR to review. If omitted, detects from current branch |
| `--threshold` | `0.8` | Minimum confidence score (0-1) for reporting findings |
| `--model` | `gpt-5.3-codex` | Codex model to use |
| `--chunk-size` | `3000` | Lines per chunk. Diffs exceeding this are split and reviewed in parallel |
| `--max-parallel` | `6` | Max concurrent `codex exec` calls during chunked review |
| `--max-diff-lines` | `0` | Safety truncation cap (0 = unlimited; chunking handles any size) |
| `--no-verify` | off | Skip the post-synthesis verification pass |

## How It Works

The skill builds a structured prompt from a template (`scripts/codex-prompt.md`) that includes:

- The PR diff (from `gh pr diff`, with a `git diff` fallback if the GitHub API rejects the diff for size)
- Any `CLAUDE.md` project rules found in the repo root
- A PR-wide manifest of changed files and added symbols, so each chunk has cross-chunk context
- Review criteria covering correctness, security, performance, and maintainability

Codex returns structured JSON matching the output schema (`scripts/codex-output-schema.json`), which includes:

- Individual findings with title, body, confidence score, priority, and code location
- An overall correctness verdict with explanation
- Iteration metadata for follow-up reviews

The script then formats the results into a readable PR comment with a summary table and expandable details.

### Large PR Chunking

PRs whose diff exceeds `--chunk-size` lines are split along file and hunk boundaries (never mid-hunk) using `scripts/chunk-diff.awk` and reviewed by parallel `codex exec` calls (capped by `--max-parallel`, default 6). Failed chunks are retried up to 3 times with exponential backoff, and any chunks that ultimately fail have their stderr and prompt preserved in `/tmp/codex-pr-review-failures-*` for diagnosis. The PR comment surfaces a coverage warning if any chunks failed.

Chunk results are then synthesized by a final `codex exec` that deduplicates findings, applies cross-chunk reasoning, and emits the same schema as a single-chunk review.

### Verification Pass

After synthesis on chunked reviews, a separate `codex exec` re-checks each finding against the raw diff to drop hallucinations and tighten confidence scores. The pass is non-blocking — if it fails, the unverified output is used and a warning is emitted. Disable it with `--no-verify`.

### Follow-up Reviews

When a PR has been reviewed before, prior Codex review comments are detected via embedded metadata. The follow-up review reports which prior findings have been resolved, which persist (labeled `[PERSISTING]`), and any new issues introduced by fix commits. The summary JSON includes `review_iteration` and `resolved_prior_findings`.

### Output Schema

Each finding includes:

| Field | Type | Description |
|-------|------|-------------|
| `title` | string | Short summary (max 80 chars) |
| `body` | string | Detailed explanation with suggested fix |
| `confidence_score` | number (0-1) | How confident the model is this is a real issue |
| `priority` | int (0-3) | 0=info, 1=low, 2=medium, 3=high |
| `code_location` | object | File path, start line, end line |

### Exit Codes

| Code | Meaning |
|------|---------|
| 0 | Success -- review posted |
| 1 | Missing prerequisite (codex, gh, or OAuth not configured) |
| 2 | PR not found or empty diff |
| 3 | Codex execution failed |
| 4 | Failed to post PR comment (review still printed to stdout) |

## Project Structure

```
codex-pr-review/
├── SKILL.md                            # Claude Code skill definition
├── install.sh                          # One-step installer
├── LICENSE
├── README.md
└── scripts/
    ├── review.sh                       # Main orchestration script
    ├── chunk-diff.awk                  # Splits large diffs along file/hunk boundaries
    ├── codex-prompt.md                 # Single-chunk review prompt template
    ├── codex-chunk-prompt.md           # Per-chunk prompt template (chunked path)
    ├── codex-synthesis-prompt.md       # Cross-chunk synthesis prompt template
    ├── codex-verification-prompt.md    # Post-synthesis verification prompt template
    ├── codex-followup-context.md       # Prior-review context block for follow-ups
    └── codex-output-schema.json        # Structured output schema
```

## License

MIT
