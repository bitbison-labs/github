#!/usr/bin/env bash
# What a branch or tag pins, recorded with no review: a tag, a new
# branch, another branch's push or a run asked for by hand (snapshot);
# or a deleted branch or tag, whose pins end (forget). Best effort: a
# failure warns and never fails the job.
set -uo pipefail

warn() { echo "::warning::bitbison: $*"; }

case $MODE in
  snapshot)
    args=(--json ci snapshot --ref "$REF")
    [ -n "${DEFAULT_BRANCH:-}" ] && args+=(--default-branch "$DEFAULT_BRANCH")
    ;;
  forget) args=(--json ci forget --ref "$REF") ;;
  *)
    warn "unknown mode '$MODE'"
    exit 0
    ;;
esac
# The checkout's credential is not needed: nothing is fetched.
git config --local --unset-all http.https://github.com/.extraheader 2> /dev/null || true
out=$(sh "$LAUNCHER" "${args[@]}" 2> "$DIR/refs.err") || true
if ! jq -e 'has("ref")' > /dev/null 2>&1 <<< "$out"; then
  warn "bitbison ci $MODE failed: $(jq -r '.error // empty' <<< "$out" 2> /dev/null)$(head -c 300 "$DIR/refs.err")"
  exit 0
fi
case $MODE in
  snapshot)
    line=$(jq -r '"\(.ref.kind) \(.ref.name) at \(.ref.revision[0:12]): \(.releases) release(s) pinned, \(.ref.added) added, \(.ref.removed) removed\(if .ref.applied then "" else " (not applied: the ref is recorded at a later commit)" end)"' <<< "$out")
    ;;
  forget)
    line=$(jq -r 'if .ref == null then "nothing was recorded for this ref" else "\(.ref.kind) \(.ref.name) deleted: \(.removed) release(s) no longer pinned" end' <<< "$out")
    ;;
esac
echo "bitbison: $line"
printf '## What this ref pins (Bitbison)\n\n%s\n' "$line" >> "${GITHUB_STEP_SUMMARY:-/dev/null}"
