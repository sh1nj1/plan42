#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
fixture_dir="$(mktemp -d)"
trap 'rm -rf "$fixture_dir"' EXIT

desktop_dir="$fixture_dir/desktop-app"
runtime_dir="$fixture_dir/node-runtime"
fake_bin="$fixture_dir/fake-bin"
mkdir -p "$desktop_dir/scripts" "$runtime_dir/bin" "$fake_bin"
cp "$PROJECT_ROOT/tools/desktop-app/scripts/bundle-proxy.sh" "$desktop_dir/scripts/bundle-proxy.sh"

cat > "$runtime_dir/bin/node" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

case "${1:-}" in
  --version) printf '%s\n' 'v22.15.0' ;;
  -p)
    case "${2:-}" in
      *realpathSync*) printf '%s/node\n' "$(cd -P "$(dirname "$0")" && pwd)" ;;
      *process.platform*) printf '%s\n' 'darwin:arm64' ;;
      *package.json*version*) printf '%s\n' '0.1.0' ;;
      *integrity*) printf '%s\n' 'sha512-test-integrity' ;;
      *) exit 1 ;;
    esac
    ;;
  -e) ;;
  *) exit 1 ;;
esac
EOF
cat > "$runtime_dir/bin/npm" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

mkdir -p node_modules/cli-openai-proxy
printf '%s\n' '{"version":"0.1.0"}' > node_modules/cli-openai-proxy/package.json
printf '%s\n' '{"packages":{"node_modules/cli-openai-proxy":{"resolved":"https://registry.npmjs.org/cli-openai-proxy/-/cli-openai-proxy-0.1.0.tgz","integrity":"sha512-test-integrity"}}}' > package-lock.json
EOF
chmod +x "$runtime_dir/bin/node" "$runtime_dir/bin/npm"

cat > "$fake_bin/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

output=""
url=""
while (($#)); do
  case "$1" in
    --output) output="$2"; shift 2 ;;
    *) url="$1"; shift ;;
  esac
done
[[ "$url" == "https://nodejs.org/dist/v22.13.0/node-v22.13.0-darwin-arm64.tar.xz" ]]
: > "$output"
EOF
cat > "$fake_bin/shasum" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

read -r checksum archive
[[ "$checksum" == "71b0893ef6a55295994f38002fada15c9a76a3cedeb36745fde0403741d183c6" ]]
[[ "$archive" == *"node-runtime.tar.xz" ]]
EOF
cat > "$fake_bin/tar" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

destination=""
while (($#)); do
  case "$1" in
    -C) destination="$2"; shift 2 ;;
    *) shift ;;
  esac
done
mkdir -p "$destination/node-v22.13.0-darwin-arm64"
cp -R "$NODE_RUNTIME_FIXTURE_DIR/." "$destination/node-v22.13.0-darwin-arm64/"
EOF
chmod +x "$fake_bin/curl" "$fake_bin/shasum" "$fake_bin/tar"

NODE_RUNTIME_FIXTURE_DIR="$runtime_dir" PATH="$fake_bin:$PATH" \
  env -u NODE_RUNTIME_DIR -u NODE_RUNTIME_URL -u NODE_RUNTIME_SHA256 \
  "$desktop_dir/scripts/bundle-proxy.sh" >/dev/null

[[ -x "$desktop_dir/vendor/proxy/node/bin/node" ]] || {
  echo "default Node runtime was not bundled" >&2
  exit 1
}
[[ "$("$desktop_dir/vendor/proxy/node/bin/node" --version)" == "v22.15.0" ]] || {
  echo "bundled Node runtime differs from the official archive fixture" >&2
  exit 1
}
grep -Fq '"node": "v22.15.0"' "$desktop_dir/vendor/proxy/manifest.json"
