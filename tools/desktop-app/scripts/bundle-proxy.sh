#!/usr/bin/env bash
# Bundle the published cli-openai-proxy package and a private Node runtime into
# the desktop app. This is a release-build step; it never installs a global npm
# package and it never uses a user's Node installation at runtime.
#
# Optional release inputs:
#   CLI_OPENAI_PROXY_VERSION  Published, exact semver (defaults to 0.1.0)
#   NODE_RUNTIME_URL          Official darwin-arm64 Node .tar.xz URL
#   NODE_RUNTIME_SHA256       SHA-256 for exactly that archive
#
# NODE_RUNTIME_DIR may be supplied by a release job that has already fetched and
# verified the official runtime archive. It must contain bin/node and bin/npm.
# When no runtime input is set, a pinned official Node distribution is downloaded
# and verified. The packaged app never uses a developer's Node installation at
# runtime.
set -euo pipefail

SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DESKTOP_DIR="$(cd -P "$SCRIPT_DIR/.." && pwd)"
OUTPUT_DIR="$DESKTOP_DIR/vendor/proxy"
PACKAGE_NAME="cli-openai-proxy"
PACKAGE_VERSION="${CLI_OPENAI_PROXY_VERSION:-0.1.0}"
NODE_RUNTIME_DIR="${NODE_RUNTIME_DIR:-}"
NODE_RUNTIME_URL="${NODE_RUNTIME_URL:-}"
NODE_RUNTIME_SHA256="${NODE_RUNTIME_SHA256:-}"
DEFAULT_NODE_RUNTIME_URL="https://nodejs.org/dist/v22.13.0/node-v22.13.0-darwin-arm64.tar.xz"
DEFAULT_NODE_RUNTIME_SHA256="71b0893ef6a55295994f38002fada15c9a76a3cedeb36745fde0403741d183c6"

fail() {
  echo "[bundle-proxy] $*" >&2
  exit 1
}

[[ "$PACKAGE_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+([-.][0-9A-Za-z.-]+)?$ ]] || \
  fail "CLI_OPENAI_PROXY_VERSION must be an exact semver, not a range"

mkdir -p "$DESKTOP_DIR/vendor"

# The staging dir must live OUTSIDE the repository. Node resolves a module by
# walking UP the directory tree, so a stage inside the repo lets a nested package
# escape into the Rails app's own node_modules. Concretely: npm's tree for this
# dependency set never installs @esbuild/darwin-arm64, so esbuild's postinstall
# resolves "@esbuild/darwin-arm64/bin/esbuild" out of the stage, finds the app's
# copy, and aborts the build with `Expected "<a>" but got "<b>"` whenever the two
# esbuild versions differ. Outside the repo there is nothing to escape to, and
# esbuild falls back to its integrity-checked download of the matching binary.
stage="$(mktemp -d "${TMPDIR:-/tmp}/collavre-proxy.XXXXXX")"
cleanup() { rm -rf "$stage"; }
trap cleanup EXIT

# Same hazard if TMPDIR itself sits under a node_modules tree: fail loudly rather
# than bundling packages resolved from outside the stage.
probe="$stage"
while :; do
  probe="$(dirname "$probe")"
  if [[ -d "$probe/node_modules" ]]; then
    fail "staging dir is nested under $probe/node_modules; set TMPDIR to a path outside any node_modules tree"
  fi
  if [[ "$probe" == "/" ]]; then
    break
  fi
done

if [[ -n "$NODE_RUNTIME_DIR" ]]; then
  [[ -x "$NODE_RUNTIME_DIR/bin/node" && -x "$NODE_RUNTIME_DIR/bin/npm" ]] || \
    fail "NODE_RUNTIME_DIR must contain executable bin/node and bin/npm"
  cp -R "$NODE_RUNTIME_DIR" "$stage/node"
else
  if [[ -n "$NODE_RUNTIME_URL" || -n "$NODE_RUNTIME_SHA256" ]]; then
    [[ -n "$NODE_RUNTIME_URL" && -n "$NODE_RUNTIME_SHA256" ]] || \
      fail "set both NODE_RUNTIME_URL and NODE_RUNTIME_SHA256"
  else
    NODE_RUNTIME_URL="$DEFAULT_NODE_RUNTIME_URL"
    NODE_RUNTIME_SHA256="$DEFAULT_NODE_RUNTIME_SHA256"
  fi
  [[ "$NODE_RUNTIME_URL" == https://nodejs.org/* ]] || \
    fail "NODE_RUNTIME_URL must use the official nodejs.org HTTPS distribution"
  archive="$stage/node-runtime.tar.xz"
  curl --fail --location --proto '=https' --tlsv1.2 --output "$archive" "$NODE_RUNTIME_URL"
  printf '%s  %s\n' "$NODE_RUNTIME_SHA256" "$archive" | shasum -a 256 -c -
  tar -xJf "$archive" -C "$stage"
  rm -f "$archive"
  runtime_root="$(find "$stage" -mindepth 1 -maxdepth 1 -type d -name 'node-v*-darwin-arm64' -print -quit)"
  [[ -n "$runtime_root" ]] || fail "Node archive is not a darwin-arm64 distribution"
  mv "$runtime_root" "$stage/node"
fi

node_bin="$stage/node/bin/node"
npm_bin="$stage/node/bin/npm"
[[ "$("$node_bin" -p 'process.platform + ":" + process.arch')" == "darwin:arm64" ]] || \
  fail "the bundled Node runtime must be darwin:arm64"
node_version="$("$node_bin" --version)"
export PATH="$stage/node/bin:$PATH"
cd "$stage"

# npm writes the release-local lockfile before installing. The subsequent install
# uses that lockfile, including exact resolved tarball URLs and integrity values.
cat > "$stage/package.json" <<EOF
{
  "private": true,
  "name": "collavre-desktop-proxy-runtime",
  "version": "1.0.0",
  "dependencies": {
    "$PACKAGE_NAME": "$PACKAGE_VERSION"
  }
}
EOF

# The registry is intentionally contacted only in the release build. The final
# DMG contains the resolved dependency tree and has no first-run network install.
"$npm_bin" install --package-lock-only --ignore-scripts
"$npm_bin" install --omit=dev

resolved_version="$("$node_bin" -p "require('./node_modules/$PACKAGE_NAME/package.json').version")"
[[ "$resolved_version" == "$PACKAGE_VERSION" ]] || \
  fail "npm resolved $PACKAGE_NAME@$resolved_version instead of $PACKAGE_VERSION"

"$node_bin" -e '
  const fs = require("fs");
  const lock = JSON.parse(fs.readFileSync("package-lock.json", "utf8"));
  const item = lock.packages && lock.packages["node_modules/cli-openai-proxy"];
  if (!item || !item.resolved || !item.integrity) process.exit(1);
'
package_integrity="$("$node_bin" -p "JSON.parse(require('fs').readFileSync('package-lock.json', 'utf8')).packages['node_modules/$PACKAGE_NAME'].integrity")"

cat > "$stage/manifest.json" <<EOF
{
  "package": "$PACKAGE_NAME",
  "version": "$PACKAGE_VERSION",
  "integrity": "$package_integrity",
  "node": "$node_version",
  "platform": "darwin-arm64"
}
EOF

rm -rf "$OUTPUT_DIR"
cd "$DESKTOP_DIR"
# TMPDIR may be on a different volume than the repo, so fall back to a copy.
if ! mv "$stage" "$OUTPUT_DIR" 2>/dev/null; then
  cp -Rp "$stage" "$OUTPUT_DIR"
  rm -rf "$stage"
fi
trap - EXIT
echo "[bundle-proxy] bundled $PACKAGE_NAME@$PACKAGE_VERSION with $node_version"
