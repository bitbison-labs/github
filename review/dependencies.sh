#!/usr/bin/env bash
# The pull request's direct dependency changes through what the grant
# workflow settles without a model, and the prompt for what is left.
set -uo pipefail
. "$(dirname "$0")/prompt.sh"

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

{
  echo "ok=true"
  echo "changes=$(jq -r .changes <<< "$out")"
  echo "submodules=$(jq -r .submodules <<< "$out")"
} >> "$GITHUB_OUTPUT"
prompt=$(jq -r '.prompt // empty' <<< "$out")
# Opt-in: the direct changes' advisories, and the relevance review's
# prompt beside the dependency review's when any carries one.
if [ "${VULNERABILITIES:-false}" = true ]; then
  vout=$(sh "$LAUNCHER" --json ci vulnerabilities --state "$DIR/dependencies.json" 2>> "$DIR/ci.err") || true
  if jq -e 'has("vulnerable")' > /dev/null 2>&1 <<< "$vout"; then
    echo "bitbison: $(jq -r .vulnerable <<< "$vout") direct dependency change(s) with an advisory"
    vprompt=$(jq -r '.prompt // empty' <<< "$vout")
    [ -n "$vprompt" ] && prompt="${prompt:+$prompt$'\n\n'}$vprompt"
  else
    echo "::warning::bitbison: bitbison ci vulnerabilities failed: $(head -c 300 "$DIR/ci.err")"
  fi
fi
prompt_output "$prompt"
