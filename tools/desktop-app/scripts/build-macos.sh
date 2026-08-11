#!/usr/bin/env bash
# Build the Collavre macOS .app: stage the Rails app, vendor Ruby + gems,
# precompile assets, then run `tauri build` to produce the bundle.
#
# Output: "tools/desktop-app/src-tauri/target/release/bundle/macos/Collavre Desktop.app"
#
# Prerequisites:
#   - Rust toolchain (cargo) + Tauri CLI (`cargo install tauri-cli --version '^2'`)
#   - ruby-build (brew install ruby-build)
#   - Node.js + npm (jsbundling-rails/esbuild needs node_modules for precompile)
#   - libvips (brew install vips) for image_processing native build
# Code signing / notarization are intentionally NOT done here (v1 runs locally;
# right-click → Open to bypass Gatekeeper). See README.
set -euo pipefail

SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DESKTOP_DIR="$(cd -P "$SCRIPT_DIR/.." && pwd)"
APP_ROOT="$(cd -P "$DESKTOP_DIR/../.." && pwd)"
STAGING="$DESKTOP_DIR/staging/app"
# An absolute CARGO_TARGET_DIR lets release builds reuse a verified Cargo cache
# without changing where staging or the final bundle are resolved.
TAURI_TARGET_DIR="${CARGO_TARGET_DIR:-$DESKTOP_DIR/src-tauri/target}"

echo "[build-macos] 1/7 vendoring Ruby + gems"
"$SCRIPT_DIR/bundle-ruby.sh"

echo "[build-macos] 2/7 bundling cli-openai-proxy"
"$SCRIPT_DIR/bundle-proxy.sh"

# jsbundling-rails drives esbuild from node_modules during assets:precompile, so
# the JS deps must be installed first (same as the Dockerfile/Render build). A
# clean checkout or CI runner has no node_modules, so precompile fails without this.
echo "[build-macos] 3/7 installing Node packages (npm ci)"
(
  cd "$APP_ROOT"
  npm ci
)

echo "[build-macos] 4/7 precompiling assets (desktop env)"
(
  cd "$APP_ROOT"
  export PATH="$DESKTOP_DIR/vendor/ruby/bin:$PATH"
  export BUNDLE_PATH="$DESKTOP_DIR/vendor/bundle"
  export BUNDLE_WITHOUT="development:test:production"
  export BUNDLE_WITH="desktop"
  RAILS_ENV=desktop SECRET_KEY_BASE_DUMMY=1 \
    "$DESKTOP_DIR/vendor/ruby/bin/ruby" -S bundle exec rails assets:precompile
)

echo "[build-macos] 5/7 staging app tree into $STAGING"
rm -rf "$DESKTOP_DIR/staging"
mkdir -p "$STAGING"
# Copy the app, excluding VCS, dev cruft, tests, and per-run state. The vendored
# Ruby/gems under tools/desktop-app/vendor ARE included (the app needs them) — the
# --include below protects that whole tree from the unanchored test/spec excludes:
# rsync matches a bare 'test'/'spec' at ANY depth, which otherwise strips real gem
# library code living under a dir named test/ (e.g. rack-test's lib/rack/test/ —
# cookie_jar.rb), corrupting the bundle and crashing boot with a LoadError.
# Secrets are excluded so a developer's local credentials never get baked into a
# distributable .app: the desktop env provisions its own SECRET_KEY_BASE at first
# run and never decrypts credentials, so any config/*.key / .env* are pure liability
# (.gitignore treats every /config/*.key as a local secret, not just master.key).
# .bundle is excluded too: a developer's local `bundle config set --local` writes
# .bundle/config, which outranks the launcher's BUNDLE_PATH env and would point the
# packaged app at a dev-only gem path. The launcher sets all bundler env at runtime.
rsync -a --delete \
  --exclude '.git' \
  --exclude 'node_modules' \
  --exclude 'log/*' \
  --exclude 'tmp/*' \
  --exclude 'storage/*' \
  --exclude '/tools/desktop-app/vendor/proxy/***' \
  --include 'tools/desktop-app/vendor/**' \
  --exclude 'test' \
  --exclude 'spec' \
  --exclude '.env' \
  --exclude '.env.*' \
  --exclude '.bundle' \
  --exclude 'config/*.key' \
  --exclude 'config/credentials/*.key' \
  --exclude 'tools/desktop-app/staging' \
  --exclude 'tools/desktop-app/src-tauri/target' \
  "$APP_ROOT/" "$STAGING/"

# Rails creates runtime files below Rails.root/tmp when starting the server.
# The app bundle is read-only once distributed, so the directory itself must
# already exist in the staged app even though its contents stay excluded.
mkdir -p "$STAGING/tmp/pids"

# tauri-build opens every staged file to bundle it as a resource; if any file is
# not owner-readable the resource walk aborts with EACCES. A mode-only `chmod -R`
# is not enough: on a managed/corporate Mac the checkout can carry inherited ACLs
# (and rarely file flags) that deny owner access and SURVIVE chmod's mode bits, so
# the walk still fails after a mode fix. Strip ACLs and flags first, then normalize
# mode — those three are the only things that can deny owner read. The staging tree
# is a throwaway copy that becomes read-only .app resources, so this is safe.
chmod -RN "$STAGING"                              # drop inherited/explicit ACLs
chflags -R nouchg "$STAGING" 2>/dev/null || true  # clear immutable flags if present
chmod -R u+rwX "$STAGING"                          # normalize POSIX mode bits

# The proxy is a separate Tauri resource rather than part of the Rails source
# tree. Its Node runtime and exact npm dependency tree are immutable after this
# point and are covered by the same code signature as the final .app.
mkdir -p "$STAGING/proxy"
rsync -a --delete "$DESKTOP_DIR/vendor/proxy/" "$STAGING/proxy/"

# Generate the Tauri icon set from the existing app icon. tauri.conf.json points
# at src-tauri/icons/, which is .gitignored (generated, not committed) — without
# this step `cargo tauri build` fails on a missing icon. Source of truth is the
# app's own icon under public/, so the desktop app can't drift from the brand.
echo "[build-macos] 6/7 generating app icons"
ICON_SRC="$(ls "$APP_ROOT"/public/icon-*.png 2>/dev/null | head -1)"
[ -n "$ICON_SRC" ] || { echo "no source icon at $APP_ROOT/public/icon-*.png"; exit 1; }
(
  cd "$DESKTOP_DIR/src-tauri"
  cargo tauri icon "$ICON_SRC"
)

# tauri-build (src-tauri/build.rs) copies every staged resource into
# target/<profile>/app via std::fs::copy, which PRESERVES the source mode bits.
# Vendored gems ship many 0444 (read-only) doc files, so the copies land read-only.
# On the next build, fs::copy can't truncate the existing read-only destination and
# aborts with a path-less "Permission denied (os error 13)" — the staging tree is
# fine (and re-normalized above); the unwritable files are the copies under target/,
# which cargo never cleans. Make any prior copy tree owner-writable so the re-copy
# can overwrite it. chmod (not rm): if the build script doesn't re-run, the existing
# copies must stay in place or the bundle loses its resources.
for app_copy in "$TAURI_TARGET_DIR"/*/app; do
  [ -d "$app_copy" ] && chmod -R u+w "$app_copy" 2>/dev/null || true
done

echo "[build-macos] 7/7 building the Tauri bundle"
(
  cd "$DESKTOP_DIR/src-tauri"
  # CI=true makes Tauri's bundle_dmg.sh skip the AppleScript step that styles the
  # DMG's Finder window (icon layout / background). That step sends Apple events to
  # Finder, which needs Automation (TCC) permission and fails with "failed to run
  # bundle_dmg.sh" on managed or headless Macs. Skipping it yields a plain but fully
  # functional .dmg; the .app target is unaffected. Preserve a real CI value if set.
  CI="${CI:-true}" cargo tauri build
)

# Verify the exact runtime copied into the .app, not merely the source vendor
# directory. A desktop bundle must never rely on a target Mac's system Ruby.
BUNDLED_RUBY="$TAURI_TARGET_DIR/release/bundle/macos/Collavre Desktop.app/Contents/Resources/app/tools/desktop-app/vendor/ruby/bin/ruby"
[ -x "$BUNDLED_RUBY" ] || {
  echo "[build-macos] packaged Ruby is missing or not executable: $BUNDLED_RUBY" >&2
  exit 1
}
"$BUNDLED_RUBY" -v

echo "[build-macos] done →"
echo "  $DESKTOP_DIR/src-tauri/target/release/bundle/macos/Collavre Desktop.app"
echo "Run it once via: right-click → Open (unsigned, Gatekeeper)."
