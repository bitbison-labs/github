# Sourced by dependencies.sh and build.sh. The prompt is the deployment's and
# never the public's: each of its lines is masked before it becomes the step's
# output, so the step that hands it to Claude shows *** in its log wherever the
# prompt would appear (the action's inputs, its environment).
#
# claude-code-action carries its prompt in the environment of the step that
# runs Claude, as it is and again as JSON among all its inputs, and the kernel
# starts no process with a string over 128 KiB in its environment ("Argument
# list too long"). A build's analysis alone can be several times that. A
# prompt that would not fit, measured as that JSON with room left for the
# other inputs, stays in a file that only the reviewer is allowed to read
# (setup.sh), and the prompt handed over says to read it: nothing of it is in
# a log, so nothing is masked.
PROMPT_LIMIT=98304

prompt_output() {
  local prompt=$1 line delimiter file="$DIR/prompt.md" bytes
  rm -f "$file"
  bytes=$(jq -Rsa . <<< "$prompt" | wc -c)
  if [ "${bytes:-0}" -gt "$PROMPT_LIMIT" ]; then
    printf '%s\n' "$prompt" > "$file"
    echo "bitbison: the prompt is $(wc -c < "$file") bytes, more than a step's environment carries; the reviewer reads it from $file."
    prompt="Your instructions for this task are in the file $file: they are too long to give here.

Read that file with the Read tool before anything else, from its first line to its last. It is $(wc -l < "$file") lines long, more than one read returns: read it in parts, with offset and limit, until you have read its last line. Then do what it says, as if it had been this message.

If the file cannot be read, or not to its end, you have no instructions: do nothing else, and say only that the instructions could not be read. Where an answer in a set form is still required of you, give the one that reports a risk or a failure, never the one that passes, and say why in it."
  else
    while IFS= read -r line; do
      line=${line%$'\r'}
      [ "${#line}" -ge 4 ] || continue
      echo "::add-mask::${line//%/%25}"
    done <<< "$prompt"
  fi
  delimiter="BITBISON_$(od -An -N8 -tx1 /dev/urandom | tr -d ' \n')"
  {
    echo "prompt<<$delimiter"
    [ -n "$prompt" ] && printf '%s\n' "$prompt"
    echo "$delimiter"
  } >> "$GITHUB_OUTPUT"
}
