#!/usr/bin/env bash
# The pull request's direct dependency changes through what the grant
# workflow settles without a model, and the prompt for what is left.
set -uo pipefail

skip() { echo "::warning::bitbison: $1; review skipped."; echo "ok=false" >> "$GITHUB_OUTPUT"; exit 0; }

[[ $BASE =~ ^[0-9a-f]{40}$ ]] || skip "no base commit to compare with"
if ! git cat-file -e "$BASE^{commit}" 2> /dev/null; then
  git fetch -q --no-tags --depth 1 origin "$BASE" || skip "the base commit could not be fetched"
fi
# The checkout's credential has done its work; the reviewer never sees it.
git config --local --unset-all http.https://github.com/.extraheader 2> /dev/null || true

reason="Pull request #$PR${TITLE:+: $TITLE}"
args=(--json ci dependencies --base "$BASE" --repository "$REPOSITORY" --pull-request "$PR"
  --reason "${reason:0:200}" --state "$DIR/dependencies.json")
[ "$GRANTS" = true ] || args+=(--read-only)
out=$(sh "$LAUNCHER" "${args[@]}" 2> "$DIR/ci.err") || true
jq -e 'has("changes")' > /dev/null 2>&1 <<< "$out" ||
  skip "bitbison ci dependencies failed: $(jq -r '.error // empty' <<< "$out" 2> /dev/null)$(head -c 300 "$DIR/ci.err")"
echo "bitbison: $(jq -r '"\(.changes) direct dependency change(s), \(.uncovered) uncovered, \(.submodules) submodule change(s)"' <<< "$out")"

delimiter="BITBISON_$(od -An -N8 -tx1 /dev/urandom | tr -d ' \n')"
{
  echo "ok=true"
  echo "changes=$(jq -r .changes <<< "$out")"
  echo "submodules=$(jq -r .submodules <<< "$out")"
  echo "prompt<<$delimiter"
  jq -r '.prompt // empty' <<< "$out"
  echo "$delimiter"
} >> "$GITHUB_OUTPUT"
