#!/usr/bin/env bash
# gen-large-go.sh — generate a synthetic ~6000-line Go diff with 8 functions.
# Output is written to tests/fixtures/large-go.diff. Idempotent.
set -euo pipefail

dst="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/large-go.diff"

# Each function body is ~750 lines so 8 functions span ~6000 lines total.
fn_body_lines=750
n_fns=8
total=$(( fn_body_lines * n_fns ))

{
  echo "diff --git a/internal/bigservice/handlers.go b/internal/bigservice/handlers.go"
  echo "index 0000000..1111111 100644"
  echo "--- a/internal/bigservice/handlers.go"
  echo "+++ b/internal/bigservice/handlers.go"
  printf '@@ -0,0 +1,%d @@\n' "$total"
  echo "+package bigservice"
  echo "+"
  for i in $(seq 1 "$n_fns"); do
    echo "+// HandleRequest$i is one of $n_fns synthetic handlers."
    echo "+func HandleRequest$i(ctx Context, req Request$i) (Response$i, error) {"
    for j in $(seq 1 $((fn_body_lines - 4))); do
      echo "+    // line $j of fn $i"
    done
    echo "+    return Response$i{}, nil"
    echo "+}"
  done
} > "$dst"

echo "wrote $dst ($(wc -l < "$dst") lines)"
