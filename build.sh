#!/usr/bin/env bash
# Build the Mostlymatter server binary with the OpenID Connect patch.
# Usage: BUILD_NUMBER=<id> ./build.sh <version>   (for example 12.0.2)
# Output: dist/mostlymatter-amd64-v<version>, its .sha512, its .source (the
# upstream source it was built from) and its .NOTICE.txt (Mattermost's notices)
set -euo pipefail

version=${1:?usage: BUILD_NUMBER=<id> $0 <version>}
build_number=${BUILD_NUMBER:?set BUILD_NUMBER}
if [ "$build_number" = dev ]; then
  echo "BUILD_NUMBER=dev compiles source-available enterprise code into the binary" >&2
  exit 1
fi

mostlymatter=https://framagit.org/framasoft/framateam/mostlymatter.git
upstream=https://github.com/mattermost/mattermost.git
repo=$(cd "$(dirname "$0")" && pwd)
src=$repo/build/v$version
dist=$repo/dist

rm -rf "$src"
mkdir -p "$repo/build" "$dist"
if git ls-remote --exit-code --tags "$mostlymatter" "refs/tags/v$version-limitless" >/dev/null; then
  git clone -q --depth 1 --branch "v$version-limitless" "$mostlymatter" "$src"
  source="Mostlymatter v$version-limitless ($mostlymatter)"
else
  minor=${version%.*}
  tag=$(git ls-remote --tags --refs "$mostlymatter" "v$minor.*-limitless" |
    sed 's#.*refs/tags/##' | sort -V | tail -n 1)
  if [ -z "$tag" ]; then
    echo "no Mostlymatter limitless tag for $minor" >&2
    exit 1
  fi
  git clone -q --depth 1 --branch "v$version" "$upstream" "$src"
  curl -fsSL -o "$src/limitless.patch" \
    "https://framagit.org/framasoft/framateam/mostlymatter/-/raw/$tag/limitless.patch"
  source="Mattermost v$version ($upstream) with limitless.patch from Mostlymatter $tag ($mostlymatter)"
fi

shim=11
if [ "${version%%.*}" = 10 ]; then
  shim=10
fi
cd "$src"
git apply limitless.patch "$repo/patches/openid.patch" "$repo/patches/openid-get-user-$shim.patch"

cd server
ulimit -n 8096
make validate-go-version
make setup-go-work
make build-linux-amd64 BUILD_NUMBER="$build_number"

binary=mostlymatter-amd64-v$version
cp bin/mostlymatter "$dist/$binary"
(cd "$dist" && sha512sum "$binary" > "$binary.sha512")
echo "$source" > "$dist/$binary.source"
cp "$src/NOTICE.txt" "$dist/$binary.NOTICE.txt"
echo "$dist/$binary"
