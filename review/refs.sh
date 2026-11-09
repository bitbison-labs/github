#!/usr/bin/env bash
# The state of the ref checked out, with no review: everything its tree
# pins and every branch and tag the repository has (bitbison ci
# snapshot), so a grant shows where its release is in use and a deleted
# branch or tag ends whatever event was missed. Best effort: a failure
# warns and never fails the job.
set -uo pipefail

warn() { echo "::warning::bitbison: $*"; }

args=(--json ci snapshot --ref "$REF")
[ -n "${DEFAULT_BRANCH:-}" ] && args+=(--default-branch "$DEFAULT_BRANCH")
[[ ${RUN_ID:-} =~ ^[0-9]+$ ]] && args+=(--run "$RUN_ID")
# The checkout's credential lists the repository's branches and tags; a
# review that follows fetches its base with it and then removes it.
out=$(sh "$LAUNCHER" "${args[@]}" 2> "$DIR/refs.err") || true
[ "$MODE" = snapshot ] &&
  git config --local --unset-all http.https://github.com/.extraheader 2> /dev/null || true
if ! jq -e 'has("ref")' > /dev/null 2>&1 <<< "$out"; then
  warn "bitbison ci snapshot failed: $(jq -r '.error // empty' <<< "$out" 2> /dev/null)$(head -c 300 "$DIR/refs.err")"
  exit 0
fi
line=$(jq -r '"\(.ref.kind) \(.ref.name) at \(.ref.revision[0:12]): \(.releases) release(s) pinned, \(
  if .applied | not then "not applied (a later commit is recorded)"
  elif .changed then "\(.added) added, \(.removed) removed"
  else "unchanged" end)\(
  if (.deleted | type) == "array" and (.deleted | length) > 0
  then "; ended, no longer in the repository: \([.deleted[] | "\(.kind) \(.name)"] | join(", "))"
  else "" end)"' <<< "$out")
echo "bitbison: $line"
jq -r '.listing.error // empty | "::warning::bitbison: the repository'"'"'s branches and tags were not listed, so none was ended: \(.)"' <<< "$out"
printf '## What this ref pins (Bitbison)\n\n%s\n' "$line" >> "${GITHUB_STEP_SUMMARY:-/dev/null}"
