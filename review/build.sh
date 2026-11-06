#!/usr/bin/env bash
# The run's Bitbison build, its analysis waited for, and the build review's
# prompt; nothing when the run had no Bitbison build.
set -uo pipefail

skip() { echo "::warning::bitbison: $1; review skipped."; echo "ok=false" >> "$GITHUB_OUTPUT"; exit 0; }

[[ $RUN_ID =~ ^[0-9]+$ && $RUN_ATTEMPT =~ ^[0-9]+$ ]] || skip "no run to review"
[[ $WAIT_MINUTES =~ ^[0-9]+$ ]] || WAIT_MINUTES=15
out=$(sh "$LAUNCHER" --json ci build --repository "$REPOSITORY" --pull-request "$PR" \
  --run "$RUN_ID" --attempt "$RUN_ATTEMPT" --default-branch "${DEFAULT_BRANCH:-main}" \
  --wait-minutes "$WAIT_MINUTES" 2> "$DIR/ci.err") || true
jq -e 'has("build")' > /dev/null 2>&1 <<< "$out" ||
  skip "bitbison ci build failed: $(jq -r '.error // empty' <<< "$out" 2> /dev/null)$(head -c 300 "$DIR/ci.err")"
if jq -e '.build == null' > /dev/null <<< "$out"; then
  echo "bitbison: run $RUN_ID has no Bitbison build; nothing to review."
  echo "ok=true" >> "$GITHUB_OUTPUT"
  exit 0
fi
jq -e '.analyzed' > /dev/null <<< "$out" ||
  echo "::warning::bitbison: the analysis of build $(jq -r .build <<< "$out") had not landed after $WAIT_MINUTES minutes"

delimiter="BITBISON_$(od -An -N8 -tx1 /dev/urandom | tr -d ' \n')"
{
  echo "ok=true"
  echo "prompt<<$delimiter"
  jq -r '.prompt // empty' <<< "$out"
  echo "$delimiter"
} >> "$GITHUB_OUTPUT"
