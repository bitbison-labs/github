#!/usr/bin/env bash
# The Bitbison client, as the plugin pins it: the plugin's git marketplace
# holds the launcher and the pin, and the launcher fetches the build the pin
# names, checked against its sha256.
set -uo pipefail

skip() { echo "::warning::bitbison: $1; review skipped."; echo "ok=false" >> "$GITHUB_OUTPUT"; exit 0; }

plugin="$DIR/plugin"
rm -rf "$plugin"
git clone -q --depth 1 "$MARKETPLACE" "$plugin" 2> /dev/null ||
  skip "the Bitbison plugin could not be cloned"
launcher="$plugin/bitbison/libexec/bitbison"
[ -f "$launcher" ] || skip "the Bitbison plugin carries no client launcher"
# The launcher says on stderr when it cannot run the client; the client
# alone answers on stdout.
version=$(sh "$launcher" --version 2> "$DIR/client.err")
[ -n "$version" ] || skip "the Bitbison client could not be fetched: $(head -c 300 "$DIR/client.err")"
echo "bitbison: $version"
{ echo "ok=true"; echo "launcher=$launcher"; } >> "$GITHUB_OUTPUT"
