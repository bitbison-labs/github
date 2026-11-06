#!/usr/bin/env bash
# Decides whether to review and how Claude reaches Bitbison. Best effort:
# anything missing skips the review with a warning and never fails the job.
set -uo pipefail

note() { echo "bitbison: $*"; }
warn() { echo "::warning::bitbison: $*"; }
skip() { warn "$1; review skipped."; echo "run=false" >> "$GITHUB_OUTPUT"; exit 0; }

for secret in "$CI_TOKEN" "$CHANNEL" "$ANTHROPIC_API_KEY" "$CLAUDE_CODE_OAUTH_TOKEN"; do
  [ -n "$secret" ] && echo "::add-mask::$secret"
done

# The build review also gates a push's or a dispatched run's build; the
# dependency review is a pull request's alone.
if [ "$REVIEW" = build ]; then
  case ${GATE:-report} in
    off)
      note "gate is off; nothing to do."
      echo "run=false" >> "$GITHUB_OUTPUT"
      exit 0
      ;;
    report | block | agent) ;;
    *)
      echo "::error::bitbison: gate must be off, report, block or agent, not '$GATE'"
      exit 1
      ;;
  esac
  if [ "$GATE" = agent ] && [ "$ANALYSIS" != true ]; then
    echo "::error::bitbison: gate 'agent' lets Claude decide, so it needs analysis: true"
    exit 1
  fi
elif [ -z "$PR" ]; then
  note "not a pull request; nothing to review."
  echo "run=false" >> "$GITHUB_OUTPUT"
  exit 0
fi
missing=()
for tool in curl jq gh git; do
  command -v "$tool" > /dev/null || missing+=("$tool")
done
[ ${#missing[@]} -eq 0 ] || skip "the runner has no ${missing[*]}"
[ -n "$CI_TOKEN" ] || skip "ci-token is empty (a pull request from a fork gets no secrets)"
if [ -z "$ANTHROPIC_API_KEY$CLAUDE_CODE_OAUTH_TOKEN" ] && { [ -z "$FEDERATION_RULE" ] || [ -z "$FEDERATION_ORG" ]; }; then
  skip "a Claude credential is required: anthropic-api-key, claude-code-oauth-token, or anthropic-federation-rule-id with anthropic-organization-id"
fi
[[ $MODEL =~ ^[A-Za-z0-9._:/@-]*$ ]] || skip "model is not a model name"

instance=${INSTANCE%/}
host=${instance#https://}
[ "$host" != "$instance" ] && [[ $host =~ ^[A-Za-z0-9.-]+(:[0-9]+)?$ ]] ||
  skip "instance must be an https URL with no path"

org=$ORGANIZATION
if [ -z "$org" ] && [ -n "$CHANNEL" ]; then
  path=${CHANNEL#https://*/}
  org=${path%%/*}
  [ -n "$org" ] && echo "::add-mask::$org"
fi
[[ $org =~ ^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$ || $org =~ ^[A-Za-z0-9_-]{22}$ ]] ||
  skip "organization (or channel) is required"

# The Bitbison plugin, and the client it pins, always from the latest
# channel, as the git repository claude-code-action's plugin input takes.
marketplace="$instance/$org/plugins/claude/latest/bitbison.git"
curl -fsS --proto '=https' --max-time 30 -A bitbison-github-action -o /dev/null \
  "$marketplace/info/refs?service=git-upload-pack" ||
  skip "the Bitbison plugin is not available from this instance"

case $REVIEW in
  dependencies) default_grants=true ;;
  build) default_grants=false ;;
  *) skip "review must be 'dependencies' or 'build'" ;;
esac
case ${GRANTS:-$default_grants} in
  true) grants=true ;;
  false) grants=false ;;
  *) skip "grants must be 'true' or 'false'" ;;
esac
# A build review only reads.
[ "$REVIEW" = build ] && grants=false

dir="${RUNNER_TEMP:-/tmp}/bitbison-review"
mkdir -p "$dir" && chmod 700 "$dir"
umask 077
tools='Bash(gh pr diff:*),Bash(gh pr view:*)'
schema=""
case $REVIEW in
  dependencies) tools="$tools,mcp__github_inline_comment__create_inline_comment" ;;
  build)
    # The analysis reads the change (a push has no pull request) and
    # answers a verdict the gate reads; it comments on nothing.
    tools="$tools,Bash(git show:*),Bash(git log:*),Bash(git diff:*)"
    schema='{"type":"object","properties":{"decision":{"type":"string","enum":["real_risk","no_real_risk"]},"summary":{"type":"string"},"findings":{"type":"array","items":{"type":"object","properties":{"rule":{"type":"string"},"subject":{"type":"string"},"real_risk":{"type":"boolean"},"reason":{"type":"string"},"next":{"type":"string"}},"required":["rule","real_risk","reason","next"]}},"analysis":{"type":"string"}},"required":["decision","summary","findings","analysis"]}'
    ;;
esac
plugins=""
mcp=""

if $grants; then
  plugins="bitbison@bitbison"
  tools="$tools,Bash(bitbison package:*),Bash(bitbison search:*),Bash(bitbison capture:*),Bash(bitbison report:*),Bash(bitbison grant:*),Bash(bitbison audit submit:*),Bash(bitbison requests:*)"
  tools="$tools,mcp__plugin_bitbison_bitbison__docs,mcp__plugin_bitbison_bitbison__dependency_history"
else
  # The CI MCP server: the runtime mount when the token has it, which adds
  # build_query over the masked audit views of the organization's CI
  # builds, else the plain one, the registry's tools alone. Listing tools
  # spends no allowance.
  probe() {
    curl -sS --proto '=https' --max-time 30 -o /dev/null -w '%{http_code}' -X POST "$instance/mcp/ci/$1" \
      -H "Authorization: Bearer $CI_TOKEN" \
      -H 'Content-Type: application/json' \
      -H 'Accept: application/json, text/event-stream' \
      -H 'MCP-Protocol-Version: 2025-06-18' \
      -A bitbison-github-action \
      -d '{"jsonrpc":"2.0","id":1,"method":"tools/list"}' 2> /dev/null
  }
  if [ "$(probe runtime)" = 200 ]; then
    mount=runtime
  elif [ "$(probe builds)" = 200 ]; then
    mount=builds
  else
    skip "the CI token was refused"
  fi
  jq -n --arg url "$instance/mcp/ci/$mount" --arg auth "Bearer $CI_TOKEN" \
    '{mcpServers: {bitbison: {type: "http", url: $url, headers: {Authorization: $auth}}}}' \
    > "$dir/mcp.json" || skip "could not write the MCP configuration"
  mcp="--mcp-config $dir/mcp.json"
  tools="$tools,mcp__bitbison__docs,mcp__bitbison__dependency_history,mcp__bitbison__package,mcp__bitbison__search_packages,mcp__bitbison__package_report,mcp__bitbison__package_status"
  [ "$mount" = runtime ] && tools="$tools,mcp__bitbison__build_query"
fi

{
  echo "run=true"
  echo "grants=$grants"
  echo "instance=$instance"
  echo "marketplace=$marketplace"
  echo "plugins=$plugins"
  echo "session=github:${PR:+pr-$PR:}$RUN_ID-$RUN_ATTEMPT:$REVIEW"
  echo "args=$mcp${MODEL:+ --model $MODEL}${schema:+ --json-schema '$schema'}"
  echo "tools=$tools"
  echo "dir=$dir"
} >> "$GITHUB_OUTPUT"
