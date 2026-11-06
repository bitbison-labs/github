#!/usr/bin/env bash
# The run's Bitbison build, its analysis waited for: the report of what it
# did, whether it is clean, and the analysis prompt for one that is not;
# nothing when the run had no Bitbison build.
set -uo pipefail
. "$(dirname "$0")/prompt.sh"

skip() { echo "::warning::bitbison: $1; review skipped."; echo "ok=false" >> "$GITHUB_OUTPUT"; exit 0; }

[[ $RUN_ID =~ ^[0-9]+$ && $RUN_ATTEMPT =~ ^[0-9]+$ ]] || skip "no run to review"
[[ $WAIT_MINUTES =~ ^[0-9]+$ ]] || WAIT_MINUTES=15
args=(--json ci build --repository "$REPOSITORY" --run "$RUN_ID" --attempt "$RUN_ATTEMPT"
  --default-branch "${DEFAULT_BRANCH:-main}" --wait-minutes "$WAIT_MINUTES")
[[ ${PR:-} =~ ^[0-9]+$ ]] && args+=(--pull-request "$PR")
[ -n "${GIT_REF:-}" ] && args+=(--git-ref "$GIT_REF")
out=$(sh "$LAUNCHER" "${args[@]}" 2> "$DIR/ci.err") || true
jq -e 'has("build")' > /dev/null 2>&1 <<< "$out" ||
  skip "bitbison ci build failed: $(jq -r '.error // empty' <<< "$out" 2> /dev/null)$(head -c 300 "$DIR/ci.err")"

report="$DIR/build-report.md"
jq -r '.report // empty' <<< "$out" > "$report"
{
  echo "ok=true"
  echo "build=$(jq -r '.build // empty' <<< "$out")"
  echo "analyzed=$(jq -r '.analyzed' <<< "$out")"
  echo "clean=$(jq -r '.clean' <<< "$out")"
  echo "report=$report"
} >> "$GITHUB_OUTPUT"
if jq -e '.build == null' > /dev/null <<< "$out"; then
  echo "bitbison: run $RUN_ID has no Bitbison build; nothing to review."
  exit 0
fi
jq -e '.analyzed' > /dev/null <<< "$out" ||
  echo "::warning::bitbison: the analysis of build $(jq -r .build <<< "$out") had not landed after $WAIT_MINUTES minutes"
prompt_output "$(jq -r '.prompt // empty' <<< "$out")"
