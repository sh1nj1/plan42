#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
fixture_dir="$(mktemp -d)"
trap 'rm -rf "$fixture_dir"' EXIT

desktop_dir="$fixture_dir/desktop-app"
mkdir -p "$desktop_dir/scripts" "$fixture_dir/node-runtime/bin"
cp "$PROJECT_ROOT/tools/desktop-app/scripts/bundle-proxy.sh" "$desktop_dir/scripts/bundle-proxy.sh"

cat > "$fixture_dir/node-runtime/bin/node" <<'EOF'
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
cat > "$fixture_dir/node-runtime/bin/npm" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

mkdir -p node_modules/cli-openai-proxy
printf '%s\n' '{"version":"0.1.0"}' > node_modules/cli-openai-proxy/package.json
printf '%s\n' '{"packages":{"node_modules/cli-openai-proxy":{"resolved":"https://registry.npmjs.org/cli-openai-proxy/-/cli-openai-proxy-0.1.0.tgz","integrity":"sha512-test-integrity"}}}' > package-lock.json
EOF
chmod +x "$fixture_dir/node-runtime/bin/node" "$fixture_dir/node-runtime/bin/npm"

PATH="$fixture_dir/node-runtime/bin:$PATH" \
  env -u NODE_RUNTIME_DIR -u NODE_RUNTIME_URL -u NODE_RUNTIME_SHA256 \
  "$desktop_dir/scripts/bundle-proxy.sh" >/dev/null

[[ -x "$desktop_dir/vendor/proxy/node/bin/node" ]] || {
  echo "discovered Node runtime was not bundled" >&2
  exit 1
}
[[ "$("$desktop_dir/vendor/proxy/node/bin/node" --version)" == "v22.15.0" ]] || {
  echo "bundled Node runtime differs from the discovered runtime" >&2
  exit 1
}
grep -Fq '"node": "v22.15.0"' "$desktop_dir/vendor/proxy/manifest.json"
