#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
fixture_dir="$(mktemp -d)"
trap 'rm -rf "$fixture_dir"' EXIT

app_root="$fixture_dir/app-root"
desktop_dir="$app_root/tools/desktop-app"
mkdir -p "$app_root/app/assets/builds" "$app_root/public/assets" \
  "$app_root/.claude" "$app_root/coverage" "$desktop_dir/vendor/ruby"

cat > "$app_root/.gitignore" <<'EOF'
/public/assets
/app/assets/builds/*
!/app/assets/builds/.keep
/.claude
/coverage
EOF
printf '%s\n' 'tracked app file' > "$app_root/README.md"
: > "$app_root/app/assets/builds/.keep"
printf '%s\n' '{"application.js":{"digested_path":"application-test.js"}}' \
  > "$app_root/public/assets/.manifest.json"
printf '%s\n' 'compiled JavaScript' > "$app_root/app/assets/builds/application.js"
printf '%s\n' 'digested JavaScript' > "$app_root/public/assets/application-test.js"
printf '%s\n' 'release-machine secret' > "$app_root/.claude/settings.json"
printf '%s\n' 'ignored coverage' > "$app_root/coverage/index.html"
printf '%s\n' 'vendored ruby' > "$desktop_dir/vendor/ruby/README"

git -C "$app_root" init --quiet
git -C "$app_root" add .gitignore README.md app/assets/builds/.keep

"$PROJECT_ROOT/tools/desktop-app/scripts/stage-app-tree.sh" "$app_root" "$desktop_dir"

staging="$desktop_dir/staging/app"
[[ -f "$staging/README.md" ]] || { echo "tracked source was not staged" >&2; exit 1; }
[[ -f "$staging/public/assets/.manifest.json" ]] || { echo "asset manifest was not staged" >&2; exit 1; }
[[ -f "$staging/public/assets/application-test.js" ]] || { echo "digested asset was not staged" >&2; exit 1; }
[[ -f "$staging/app/assets/builds/application.js" ]] || { echo "compiled JavaScript was not staged" >&2; exit 1; }
[[ -f "$staging/tools/desktop-app/vendor/ruby/README" ]] || { echo "vendored Ruby was not staged" >&2; exit 1; }
[[ ! -e "$staging/.claude/settings.json" ]] || { echo "ignored credential was staged" >&2; exit 1; }
[[ ! -e "$staging/coverage/index.html" ]] || { echo "ignored coverage was staged" >&2; exit 1; }

echo "build_macos_test: passed"
