#!/usr/bin/env bash
# Move each line in versions.json to its newest upstream release that build.sh
# can build (a Mostlymatter limitless tag for the version or its minor release)
# and that has a mattermost-team-edition image to test in.
set -euo pipefail

mostlymatter=https://framagit.org/framasoft/framateam/mostlymatter.git
upstream=https://github.com/mattermost/mattermost.git
cd "$(dirname "$0")"

releases=$(git ls-remote --tags --refs "$upstream" 'v*' | sed 's#.*refs/tags/v##' |
  grep -E '^[0-9]+\.[0-9]+\.[0-9]+$' | sort -rV)
limitless=$(git ls-remote --tags --refs "$mostlymatter" 'v*-limitless' |
  sed -e 's#.*refs/tags/v##' -e 's/-limitless$//')

buildable() {
  grep -qxF "$1" <<<"$limitless" || awk -v p="${1%.*}." 'index($0, p) == 1 { found = 1 } END { exit !found }' <<<"$limitless"
}
image_digest() {
  curl -fsS "https://hub.docker.com/v2/repositories/mattermost/mattermost-team-edition/tags/$1" | jq -r '.digest // empty' || true
}

entries=()
while read -r entry; do
  line=$(jq -r .line <<<"$entry")
  current=$(jq -r .version <<<"$entry")
  while read -r v; do
    [ "$v" = "$current" ] && break
    [ "$(printf '%s\n%s\n' "$v" "$current" | sort -V | tail -n 1)" = "$v" ] || break
    buildable "$v" || continue
    digest=$(image_digest "$v")
    [ -n "$digest" ] || continue
    entry=$(jq -c --arg v "$v" --arg i "mattermost/mattermost-team-edition:$v@$digest" '.version = $v | .image = $i' <<<"$entry")
    echo "$line: $current -> $v"
    break
  done < <(awk -v p="$line." 'index($0, p) == 1' <<<"$releases")
  entries+=("$entry")
done < <(jq -c '.[]' versions.json)

printf '%s\n' "${entries[@]}" | jq -s . > versions.json
