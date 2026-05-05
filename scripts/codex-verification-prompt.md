# Finding Verification Pass

You are verifying findings produced by an earlier chunked review of a pull request. For each finding below, check it against the actual diff and decide whether it is real.

## Your task

For every finding in the `findings` array, produce a verdict:

- `keep`: the finding cites a real issue visible in the diff, the line numbers match, and the described behavior is consistent with the code on those lines.
- `drop`: the finding references code that isn't in the diff, line numbers are wrong, the symbol it claims is undefined is actually present, or the described behavior doesn't match the actual code.
- `downgrade`: the finding is plausible but not verifiable from the diff alone. Reduce its confidence by 0.3 and keep it.

You have read-only access to the repository via the sandbox. When a finding references code outside the diff (e.g. a function called but defined elsewhere), read the relevant file to verify.

## Output

Return the full findings array with the following modifications applied:
- Drop findings judged `drop`.
- Reduce `confidence_score` by 0.3 (floor 0.1) for findings judged `downgrade`.
- Keep findings judged `keep` unchanged.

Preserve all other top-level fields (`overall_correctness`, `overall_explanation`, `overall_confidence_score`, `review_iteration`, `resolved_prior_findings`) from the input. Update `overall_explanation` only if dropping findings materially changes the verdict.

Use the same JSON output schema as the original review.

## Repository Access

You have read-only access to the repository checkout via the sandbox. Use it. When a finding would require knowing the content of a file not shown in the diff (imports, type definitions, call sites, tests), read the file before deciding whether to flag. Do not speculate based on file or symbol names alone.

## Raw Diff

```diff
{{DIFF}}
```

## Findings to verify

```json
{{FINDINGS}}
```
