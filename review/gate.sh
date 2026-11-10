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

DIR=${DIR:-${RUNNER_TEMP:-/tmp}}
decision() {
  if $passed; then
    echo "**Gate (\`$GATE\`): passed.** ${reason^}."
  else
    echo "**Gate (\`$GATE\`): failed.** ${reason^}."
  fi
}
# The page leads with what a reader came for: the gate's decision, the
# run's verdict and jobs, Claude's sentence on it, the findings, and
# Claude's verdict and next step for each. What the build did besides (its
# network, artifacts, dependencies) and the analysis in full are folded
# under them, so a clean build is a few lines.
cell() { jq -r "$1 // \"\" | gsub(\"[\\r\\n]+\"; \" \") | gsub(\"\\\\|\"; \"\\\\|\")"; }
{
  if [ -s "${REPORT:-}" ]; then
    head -n 1 "$REPORT"
    echo
    decision
    # The headline and the jobs: everything before the first section.
    awk 'NR > 1 { if (/^### /) exit; print }' "$REPORT"
  else
    decision
    echo
  fi
  if [ -n "$verdict" ]; then
    jq -r '.summary // empty' <<< "$ANALYSIS"
    echo
  fi
  [ -s "${REPORT:-}" ] && awk '/^### /{ on = ($0 == "### Findings") } on' "$REPORT"
  if [ -n "$verdict" ] && jq -e '(.findings // []) | length > 0' > /dev/null 2>&1 <<< "$ANALYSIS"; then
    printf '%s\n\n' "**Claude's verdict on each open finding**"
    echo "| Finding | Real risk | Why | Next step |"
    echo "|---|---|---|---|"
    n=$(jq '.findings | length' <<< "$ANALYSIS")
    for ((i = 0; i < n; i++)); do
      f=$(jq ".findings[$i]" <<< "$ANALYSIS")
      subject=$(cell .subject <<< "$f")
      printf '| `%s`%s | %s | %s | %s |\n' "$(cell .rule <<< "$f" | tr -d '`')" \
        "${subject:+ \`${subject//\`/}\`}" \
        "$(jq -r 'if .real_risk then "**yes**" else "no" end' <<< "$f")" \
        "$(cell .reason <<< "$f")" "$(cell .next <<< "$f")"
    done
    echo
  fi
  if [ -s "${REPORT:-}" ] && grep -q '^### ' "$REPORT" &&
    [ -n "$(awk '/^### /{ on = ($0 != "### Findings") } on' "$REPORT")" ]; then
    printf '<details><summary>What the build did: network, artifacts, dependencies</summary>\n\n'
    awk '/^### /{ on = ($0 != "### Findings") } on' "$REPORT"
    printf '\n</details>\n\n'
  fi
  if [ -n "$verdict" ] && [ -n "$(jq -r '.analysis // empty' <<< "$ANALYSIS")" ]; then
    printf "<details><summary>Claude's analysis in full</summary>\n\n"
    jq -r '.analysis' <<< "$ANALYSIS"
    printf '\n</details>\n'
  fi
} > "$DIR/gate.md"
cat "$DIR/gate.md" >> "$summary"

# The report as a check on the commit the run built: it shows in the pull
# request's Checks tab beside the build, and a failed gate's check opens on
# it rather than on a log. Best effort: a token that cannot write checks
# leaves the job's summary as the report.
if [ -n "${HEAD_SHA:-}" ] && [ -n "${GH_TOKEN:-}" ]; then
  title=$(decision | sed -e 's/\*\*//g' -e 's/`//g')
  conclusion=$($passed && echo success || echo failure)
  body=$(jq -n --arg sha "$HEAD_SHA" --arg conclusion "$conclusion" --arg title "${title:0:200}" \
    --rawfile summary "$DIR/gate.md" --arg url "${RUN_URL:-}" \
    '{name: "Bitbison build report", head_sha: $sha, status: "completed", conclusion: $conclusion,
      details_url: (if $url == "" then null else $url end),
      output: {title: $title, summary: ($summary | .[0:65000])}}')
  gh api -X POST "repos/$REPOSITORY/check-runs" --input - <<< "$body" > /dev/null 2> "$DIR/check.err" ||
    echo "::warning::bitbison: the build report could not be posted as a check: $(head -c 200 "$DIR/check.err")"
fi

echo "passed=$passed" >> "$GITHUB_OUTPUT"
if ! $passed; then
  echo "::error::bitbison: the build gate failed: $reason"
  exit 1
fi
echo "bitbison: the build gate passed: $reason"
