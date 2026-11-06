#!/usr/bin/env bash
# The build review's outcome: the report, Claude's analysis when it ran,
# and the gate's decision on the job's summary; the job fails when the
# gate does.
set -uo pipefail

summary=${GITHUB_STEP_SUMMARY:-/dev/stdout}
verdict=""
[ -n "${ANALYSIS:-}" ] && verdict=$(jq -r '.decision // empty' <<< "$ANALYSIS" 2> /dev/null)

if [ -z "${BUILD:-}" ]; then
  passed=true reason="the run had no Bitbison build"
elif [ "$ANALYZED" != true ]; then
  timeout=${ON_TIMEOUT:-}
  [ -n "$timeout" ] || { [ "$GATE" = report ] && timeout=pass || timeout=fail; }
  [ "$timeout" = pass ] && passed=true || passed=false
  reason="the analysis had not landed (on-timeout: $timeout)"
elif [ "$CLEAN" = true ]; then
  passed=true reason="the build is clean"
else
  case $GATE in
    report) passed=true reason="the build is not clean; the gate only reports" ;;
    block) passed=false reason="the build is not clean; a person accepts a finding with a policy, or the change removes it" ;;
    agent)
      case $verdict in
        no_real_risk) passed=true reason="Claude found no real risk in what was flagged" ;;
        real_risk) passed=false reason="Claude found a real risk" ;;
        *) passed=false reason="Claude gave no decision (${CLAUDE:-not run}), so the flagged build fails" ;;
      esac
      ;;
  esac
fi

{
  [ -s "${REPORT:-}" ] && cat "$REPORT"
  if [ -n "$verdict" ]; then
    jq -r '.analysis // empty' <<< "$ANALYSIS"
    echo
  fi
  if $passed; then
    echo "**Gate (\`$GATE\`): passed.** ${reason^}."
  else
    echo "**Gate (\`$GATE\`): failed.** ${reason^}."
  fi
} >> "$summary"

echo "passed=$passed" >> "$GITHUB_OUTPUT"
if ! $passed; then
  echo "::error::bitbison: the build gate failed: $reason"
  exit 1
fi
echo "bitbison: the build gate passed: $reason"
