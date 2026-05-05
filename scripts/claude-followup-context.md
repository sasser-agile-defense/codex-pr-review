## Prior Review Context

**Iteration mode:** {{ITERATION_MODE}}

You are Claude. This is a **follow-up review** (iteration {{REVIEW_ITERATION}}). A previous review (running both Codex and Claude in parallel) was conducted on this PR. The developer has since pushed changes.

### Previous Review Results

**Prior verdict:** {{PRIOR_VERDICT}} (confidence: {{PRIOR_CONFIDENCE}})
**Prior summary:** {{PRIOR_EXPLANATION}}

### Previous Findings

```json
{{PRIOR_FINDINGS}}
```

## Delta since prior review

{{DELTA_BLOCK}}

### Follow-up Review Instructions

In addition to the standard review criteria, you MUST:

1. **Assess prior findings** — For each finding from the previous review, determine whether the current diff resolves it. If resolved, add the finding's title to `resolved_prior_findings`. If the finding persists (not fixed or incompletely fixed), include it in your findings with `"status": "persisting"`.
2. **Verify fix correctness** — When a prior finding has been addressed, verify the fix is correct and complete. A bad fix is worse than an unfixed issue — flag regressions with high priority.
3. **New issues** — Flag any new issues with `"status": "new"`. Apply the same review criteria as a standard review.
4. **Set review_iteration** — Set `review_iteration` to {{REVIEW_ITERATION}}.
5. **Update verdict** — Your overall verdict should reflect the **current state** of the PR, accounting for both fixes and any remaining or new issues.
6. **Summarize progress** — In `overall_explanation`, briefly note what was fixed, what remains, and any new concerns.

### Iteration mode guidance

- `initial` — Treat this as a fresh review; ignore the prior context above.
- `followup-after-fixes` — Commits since the prior review are fix-flavored. Re-evaluate every prior finding in light of the current full diff.
- `delta-since-prior` — You are reviewing only the commits since the last review (SHA `{{PRIOR_SHA}}`). The following prior findings are carried forward — assess whether each is resolved in the delta or still present. Flag new issues introduced by the delta commits and any previously-resolved findings that have regressed.
