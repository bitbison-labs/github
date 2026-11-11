#!/usr/bin/env bash
# The final check, posted as one comment the job keeps up to date, and the
# job's summary. A pull request that changes no dependency or submodule gets
# nothing, unless it had a summary from an earlier push, which is brought up
# to date. A push has no pull request to comment on: its summary, with the
# reviewer's notes under it, is the job's. The job's annotation says where
# the change stands whatever fail-on is: an error for a change your
# organization has said no to (a rule denies the release, yours or the
# built-in one for a release reviewed or reported as malicious; an approved
# audit denies it; its grant was revoked), a warning for one that waits on a
# person, a notice when everything is covered. The job fails only when
# asked to, by fail-on:
#
# - never (the default): the job only reports.
# - denied: the job fails on a denied change; one that waits on a person
#   passes.
# - uncovered: the job fails on any change no grant covers.
set -uo pipefail

mode=${FAIL_ON:-never}
# fail-on-uncovered: true, from before fail-on, is fail-on: uncovered.
[ "${FAIL_ON_UNCOVERED:-}" = true ] && mode=uncovered
case $mode in
  denied | uncovered | never) ;;
  *)
    echo "::warning::bitbison: fail-on is never, denied or uncovered, not '$mode'; taken as never, so the job only reports"
    mode=never
    ;;
esac

out=$(sh "$LAUNCHER" --json ci summary --state "$DIR/dependencies.json" 2> "$DIR/summary.err") || true
if ! jq -e 'has("summary")' > /dev/null 2>&1 <<< "$out"; then
  echo "::warning::bitbison: the final check failed: $(jq -r '.error // empty' <<< "$out" 2> /dev/null)$(head -c 300 "$DIR/summary.err")"
  exit 0
fi
summary=$(jq -r .summary <<< "$out")
uncovered=$(jq -r .uncovered <<< "$out")
# A client from before it told the denied apart reports none, so
# fail-on: denied would fail nothing and say nothing: say so.
denied=$(jq -r '.denied // empty' <<< "$out")
if [ -z "$denied" ]; then
  denied=0
  [ "$mode" = denied ] && [ "$uncovered" -gt 0 ] &&
    echo "::warning::bitbison: this Bitbison client does not say which uncovered changes are denied, so fail-on: denied fails nothing here; fail-on: uncovered fails on every uncovered change"
fi
changed=$(jq -r '(.changes // 0) + (.submodules // 0) + (.removed // 0)' <<< "$out")

# Where the change stands, as the job's annotation (red, amber, green)
# whatever fail-on is, and the job's outcome: it fails on what fail-on names
# and on nothing else.
conclude() {
  local waiting=$((uncovered - denied))
  echo "uncovered=$uncovered" >> "$GITHUB_OUTPUT"
  echo "denied=$denied" >> "$GITHUB_OUTPUT"
  if [ "$denied" -gt 0 ]; then
    local said="$denied direct dependency change(s) your organization has denied"
    [ "$waiting" -gt 0 ] && said="$said, and $waiting more that wait on a person"
    # Red either way; the job fails only when asked to.
    if [ "$mode" = never ]; then
      echo "::error title=Bitbison dependency review::$said; the summary says why. The job passes: fail-on is never"
      return 0
    fi
    echo "::error title=Bitbison dependency review::$said; the summary says why"
    return 1
  fi
  if [ "$uncovered" -gt 0 ]; then
    echo "::warning title=Bitbison dependency review::$uncovered direct dependency change(s) wait on a person; the summary says what they must decide"
    [ "$mode" = uncovered ] || return 0
    echo "::error::bitbison: $uncovered direct dependency change(s) no grant covers (fail-on: uncovered)"
    return 1
  fi
  # Nothing to say of a change that only removes or moves a submodule.
  [ "$(jq -r '.changes // 0' <<< "$out")" -gt 0 ] &&
    echo "::notice title=Bitbison dependency review::every direct dependency change is covered; the summary lists them"
  return 0
}

if [ -z "${PR:-}" ]; then
  if [ "$changed" -eq 0 ]; then
    echo "bitbison: the push changes no dependency; nothing to say."
    echo "uncovered=0" >> "$GITHUB_OUTPUT"
    echo "denied=0" >> "$GITHUB_OUTPUT"
    exit 0
  fi
  {
    printf '%s\n' "$summary"
    # The reviewer's notes, when it ran and answered.
    jq -r 'select((.notes // []) | length > 0)
      | "\n### Notes from the review\n", (.notes[] | "**`\(.package)`**\n\n\(.note)\n")' \
      <<< "${NOTES:-}" 2> /dev/null
  } >> "$GITHUB_STEP_SUMMARY"
  conclude
  exit
fi

marker='<!-- bitbison-review: dependencies -->'
body="$marker"$'\n'"$summary"
existing=$(gh api "repos/$REPOSITORY/issues/$PR/comments" --paginate \
  --jq ".[] | select(.body | startswith(\"$marker\")) | .id" 2> /dev/null | tail -n 1)
if [ "$changed" -eq 0 ] && [ -z "$existing" ]; then
  echo "bitbison: the pull request changes no dependency; nothing to say."
  echo "uncovered=0" >> "$GITHUB_OUTPUT"
  echo "denied=0" >> "$GITHUB_OUTPUT"
  exit 0
fi
printf '%s\n' "$summary" >> "$GITHUB_STEP_SUMMARY"
if [ -n "$existing" ]; then
  gh api -X PATCH "repos/$REPOSITORY/issues/comments/$existing" -f body="$body" > /dev/null ||
    echo "::warning::bitbison: the summary comment could not be updated"
else
  gh pr comment "$PR" -R "$REPOSITORY" --body "$body" > /dev/null ||
    echo "::warning::bitbison: the summary comment could not be posted"
fi

conclude
