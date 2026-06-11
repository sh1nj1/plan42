#!/usr/bin/env bash
# Build the Collavre macOS .app: stage the Rails app, vendor Ruby + gems,
# precompile assets, then run `tauri build` to produce the bundle.
#
# Output: tools/desktop-app/src-tauri/target/release/bundle/macos/Collavre.app
#
# Prerequisites:
#   - Rust toolchain (cargo) + Tauri CLI (`cargo install tauri-cli --version '^2'`)
#   - ruby-build (brew install ruby-build)
#   - libvips (brew install vips) for image_processing native build
# Code signing / notarization are intentionally NOT done here (v1 runs locally;
# right-click → Open to bypass Gatekeeper). See README.
set -euo pipefail

SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DESKTOP_DIR="$(cd -P "$SCRIPT_DIR/.." && pwd)"
APP_ROOT="$(cd -P "$DESKTOP_DIR/../.." && pwd)"
STAGING="$DESKTOP_DIR/staging/app"

echo "[build-macos] 1/4 vendoring Ruby + gems"
"$SCRIPT_DIR/bundle-ruby.sh"

echo "[build-macos] 2/4 precompiling assets (desktop env)"
(
  cd "$APP_ROOT"
  export PATH="$DESKTOP_DIR/vendor/ruby/bin:$PATH"
  export BUNDLE_PATH="$DESKTOP_DIR/vendor/bundle"
  export BUNDLE_WITHOUT="development:test:production"
  export BUNDLE_WITH="desktop"
  RAILS_ENV=desktop SECRET_KEY_BASE_DUMMY=1 \
    "$DESKTOP_DIR/vendor/ruby/bin/ruby" -S bundle exec rails assets:precompile
)

echo "[build-macos] 3/4 staging app tree into $STAGING"
rm -rf "$DESKTOP_DIR/staging"
mkdir -p "$STAGING"
# Copy the app, excluding VCS, dev cruft, tests, and per-run state. The vendored
# Ruby/gems under tools/desktop-app/vendor ARE included (the app needs them).
rsync -a --delete \
  --exclude '.git' \
  --exclude 'node_modules' \
  --exclude 'log/*' \
  --exclude 'tmp/*' \
  --exclude 'storage/*' \
  --exclude 'test' \
  --exclude 'spec' \
  --exclude 'tools/desktop-app/staging' \
  --exclude 'tools/desktop-app/src-tauri/target' \
  "$APP_ROOT/" "$STAGING/"

echo "[build-macos] 4/4 building the Tauri bundle"
(
  cd "$DESKTOP_DIR/src-tauri"
  cargo tauri build
)

echo "[build-macos] done →"
echo "  $DESKTOP_DIR/src-tauri/target/release/bundle/macos/Collavre.app"
echo "Run it once via: right-click → Open (unsigned, Gatekeeper)."
