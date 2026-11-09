#!/usr/bin/env bash
# A pull request's or a push's direct dependency changes through what the
# grant workflow settles without a model, and the prompt for what is left.
set -uo pipefail
. "$(dirname "$0")/prompt.sh"

skip() { echo "::warning::bitbison: $1; review skipped."; echo "ok=false" >> "$GITHUB_OUTPUT"; exit 0; }

# A push's reason is its last commit, by its subject line.
if [ -n "$PR" ]; then
  reason="Pull request #$PR${TITLE:+: $TITLE}"
else
  subject=${TITLE%%$'\n'*}
  reason="Push to ${GITHUB_REF_NAME:-the branch} at $(git rev-parse --short=12 HEAD)${subject:+: $subject}"
fi
common=(--repository "$REPOSITORY" --reason "${reason:0:200}" --state "$DIR/dependencies.json")
[ -n "$PR" ] && common+=(--pull-request "$PR")
[ "$GRANTS" = true ] || common+=(--read-only)

# A push named by its ref is reviewed by coverage: its state is recorded,
# and what no grant covers and no one asked for is reviewed, with nothing
# fetched. A pull request is compared with its base.
if [ -z "$PR" ] && [ -n "${REF:-}" ]; then
  args=(--json ci dependencies --ref "$REF" "${common[@]}")
  [ -n "${DEFAULT_BRANCH:-}" ] && args+=(--default-branch "$DEFAULT_BRANCH")
  [[ ${RUN_ID:-} =~ ^[0-9]+$ ]] && args+=(--run "$RUN_ID")
else
  [[ $BASE =~ ^[0-9a-f]{40}$ ]] || skip "no base commit to compare with"
  if ! git cat-file -e "$BASE^{commit}" 2> /dev/null; then
    git fetch -q --no-tags --depth 1 origin "$BASE" || skip "the base commit could not be fetched"
  fi
  args=(--json ci dependencies --base "$BASE" "${common[@]}")
fi
out=$(sh "$LAUNCHER" "${args[@]}" 2> "$DIR/ci.err") || true
# The checkout's credential has done its work; the reviewer never sees it.
git config --local --unset-all http.https://github.com/.extraheader 2> /dev/null || true
jq -e 'has("changes")' > /dev/null 2>&1 <<< "$out" ||
  skip "bitbison ci dependencies failed: $(jq -r '.error // empty' <<< "$out" 2> /dev/null)$(head -c 300 "$DIR/ci.err")"
# What the coverage review recorded, and what a person's baseline settles.
jq -r '.ref // empty | "bitbison: \(.ref.kind) \(.ref.name) recorded\(if .applied | not then ", not applied (a later run is recorded)" elif .first then ", its first state: the baseline" else "" end)"' <<< "$out"
jq -r 'if (.baseline // 0) > 0 then "::notice::bitbison: \(.baseline) direct dependencies pinned before this branch was first recorded have no grant; a person settles them with bitbison grant baseline." else empty end' <<< "$out"
echo "bitbison: $(jq -r '"\(.changes) direct dependency change(s), \(.uncovered) uncovered, \(.submodules) submodule change(s)"' <<< "$out")"

{
  echo "ok=true"
  echo "changes=$(jq -r .changes <<< "$out")"
  echo "submodules=$(jq -r .submodules <<< "$out")"
} >> "$GITHUB_OUTPUT"
prompt=$(jq -r '.prompt // empty' <<< "$out")
# Opt-in: the direct changes' advisories, and the relevance review's
# prompt beside the dependency review's when any carries one.
if [ "${VULNERABILITIES:-off}" != off ]; then
  vout=$(sh "$LAUNCHER" --json ci vulnerabilities --state "$DIR/dependencies.json" \
    --threshold "$VULNERABILITIES" 2>> "$DIR/ci.err") || true
  if jq -e 'has("vulnerable")' > /dev/null 2>&1 <<< "$vout"; then
    echo "bitbison: $(jq -r '"\(.vulnerable) direct dependency change(s) with an advisory, \(.asked) at \(.threshold) or above"' <<< "$vout")"
    vprompt=$(jq -r '.prompt // empty' <<< "$vout")
    [ -n "$vprompt" ] && prompt="${prompt:+$prompt$'\n\n'}$vprompt"
  else
    echo "::warning::bitbison: bitbison ci vulnerabilities failed: $(head -c 300 "$DIR/ci.err")"
  fi
fi
prompt_output "$prompt"
