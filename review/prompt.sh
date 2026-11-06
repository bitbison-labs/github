# Sourced by dependencies.sh and build.sh. The prompt is the deployment's and
# never the public's: each of its lines is masked before it becomes the step's
# output, so the step that hands it to Claude shows *** in its log wherever the
# prompt would appear (the action's inputs, its environment).
prompt_output() {
  local prompt=$1 line delimiter
  while IFS= read -r line; do
    line=${line%$'\r'}
    [ "${#line}" -ge 4 ] || continue
    echo "::add-mask::${line//%/%25}"
  done <<< "$prompt"
  delimiter="BITBISON_$(od -An -N8 -tx1 /dev/urandom | tr -d ' \n')"
  {
    echo "prompt<<$delimiter"
    [ -n "$prompt" ] && printf '%s\n' "$prompt"
    echo "$delimiter"
  } >> "$GITHUB_OUTPUT"
}
