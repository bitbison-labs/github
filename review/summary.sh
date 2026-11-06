#!/usr/bin/env bash
# The final check, posted as one comment the job keeps up to date, and the
# job's summary. Fails the job only when asked to and something is
# uncovered.
set -uo pipefail

out=$(sh "$LAUNCHER" --json ci summary --state "$DIR/dependencies.json" 2> "$DIR/summary.err") || true
if ! jq -e 'has("summary")' > /dev/null 2>&1 <<< "$out"; then
  echo "::warning::bitbison: the final check failed: $(jq -r '.error // empty' <<< "$out" 2> /dev/null)$(head -c 300 "$DIR/summary.err")"
  exit 0
fi
summary=$(jq -r .summary <<< "$out")
changes=$(jq -r '.changes + .submodules' <<< "$out")
uncovered=$(jq -r .uncovered <<< "$out")
printf '%s\n' "$summary" >> "$GITHUB_STEP_SUMMARY"

marker='<!-- bitbison-review: dependencies -->'
body="$marker"$'\n'"$summary"
existing=$(gh api "repos/$REPOSITORY/issues/$PR/comments" --paginate \
  --jq ".[] | select(.body | startswith(\"$marker\")) | .id" 2> /dev/null | tail -n 1)
if [ -n "$existing" ]; then
  gh api -X PATCH "repos/$REPOSITORY/issues/comments/$existing" -f body="$body" > /dev/null ||
    echo "::warning::bitbison: the summary comment could not be updated"
elif [ "$changes" -gt 0 ]; then
  gh pr comment "$PR" -R "$REPOSITORY" --body "$body" > /dev/null ||
    echo "::warning::bitbison: the summary comment could not be posted"
fi

echo "uncovered=$uncovered" >> "$GITHUB_OUTPUT"
if [ "$FAIL_ON_UNCOVERED" = true ] && [ "$uncovered" -gt 0 ]; then
  echo "::error::bitbison: $uncovered direct dependency change(s) no grant covers"
  exit 1
fi
