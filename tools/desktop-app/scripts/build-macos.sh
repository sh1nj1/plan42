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
TAURI_SOURCE_DIR="$(cd -P "$DESKTOP_DIR/src-tauri" && pwd)"
# Cargo accepts target directories that do not exist yet, so `realpath` cannot
# normalize them reliably. Collapse lexical `.` and `..` components instead,
# preserving Cargo's src-tauri-relative interpretation for both its output and
# the staging exclusion below.
normalize_target_dir() {
	local path="$1"
	local component
	local last_index
	local -a path_components=()
	local -a normalized_components=()

	[[ "$path" == /* ]] || path="$TAURI_SOURCE_DIR/$path"
	IFS=/ read -r -a path_components <<< "$path"

	for component in "${path_components[@]}"; do
		case "$component" in
			""|.) ;;
			..)
				if ((${#normalized_components[@]})); then
					last_index=$((${#normalized_components[@]} - 1))
					unset "normalized_components[$last_index]"
				fi
				;;
			*) normalized_components+=("$component") ;;
		esac
	done

	local normalized_path=""
	for component in "${normalized_components[@]}"; do
		normalized_path+="/$component"
	done
	printf '%s\n' "${normalized_path:-/}"
}

# Resolve a caller-provided relative CARGO_TARGET_DIR where Cargo resolves it:
# from src-tauri. Export the normalized value too, so Cargo and the post-build
# checks below always operate on the same directory.
if [ -n "${CARGO_TARGET_DIR:-}" ]; then
  TAURI_TARGET_DIR="$(normalize_target_dir "$CARGO_TARGET_DIR")"
else
  TAURI_TARGET_DIR="$TAURI_SOURCE_DIR/target"
fi
export CARGO_TARGET_DIR="$TAURI_TARGET_DIR"

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
# Stage only Git-tracked application files. An exclusion list inevitably misses
# newly ignored files (including developer credentials), while this allowlist
# keeps release-machine state out of the signed application by construction.
# The generated Ruby/gem tree is the sole intentional untracked input; the
# immutable proxy is copied separately below after its runtime is bundled.
git -C "$APP_ROOT" ls-files -z | \
  rsync -a --from0 --files-from=- "$APP_ROOT/" "$STAGING/"
mkdir -p "$STAGING/tools/desktop-app/vendor"
rsync -a --delete --exclude 'proxy/***' \
  "$DESKTOP_DIR/vendor/" "$STAGING/tools/desktop-app/vendor/"

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

# Ruby is built with --enable-load-relative, so exercise the packaged runtime
# with no RUBYLIB override. This verifies that it resolves its standard library
# from inside the app without prioritizing Ruby's bundled Prism over Bundler's.
PACKAGED_RUBY_ROOT="${BUNDLED_RUBY%/bin/ruby}"
PACKAGED_APP_ROOT="${PACKAGED_RUBY_ROOT%/tools/desktop-app/vendor/ruby}"
packaged_load_relative="$("$BUNDLED_RUBY" -rrbconfig -e 'print RbConfig::CONFIG.fetch("LIBRUBY_RELATIVE")')"
[ "$packaged_load_relative" = "yes" ] || {
  echo "[build-macos] packaged Ruby is not self-relocating" >&2
  exit 1
}
PACKAGED_RUBY_TEST_DATA="$(mktemp -d)"
trap 'rm -rf "$PACKAGED_RUBY_TEST_DATA"' EXIT
env -i \
  PATH=/usr/bin:/bin \
  COLLAVRE_DATA_DIR="$PACKAGED_RUBY_TEST_DATA" \
  "$BUNDLED_RUBY" "$PACKAGED_APP_ROOT/tools/desktop-app/scripts/provision-secrets.rb" >/dev/null
env -i \
  PATH="$PACKAGED_RUBY_ROOT/bin:/usr/bin:/bin" \
  BUNDLE_GEMFILE="$PACKAGED_APP_ROOT/Gemfile" \
  BUNDLE_PATH="$PACKAGED_APP_ROOT/tools/desktop-app/vendor/bundle" \
  BUNDLE_WITHOUT="development:test:production" \
  BUNDLE_WITH="desktop" \
  COLLAVRE_DATA_DIR="$PACKAGED_RUBY_TEST_DATA" \
  RAILS_ENV=desktop \
  SECRET_KEY_BASE=0123456789012345678901234567890123456789012345678901234567890123 \
  "$BUNDLED_RUBY" "$PACKAGED_APP_ROOT/bin/rails" runner \
  'require "shellwords"; build_prefix = Shellwords.shellsplit(RbConfig::CONFIG.fetch("configure_args")).find { |argument| argument.start_with?("--prefix=") }&.delete_prefix("--prefix="); abort "Ruby build prefix is unavailable" unless build_prefix; abort "stale Ruby load path" if $LOAD_PATH.any? { |path| path == build_prefix || path.start_with?("#{build_prefix}/") }; abort "wrong Prism version" unless Gem.loaded_specs.fetch("prism").version.to_s == "1.9.0"' >/dev/null

# A Ruby executable can start on the build Mac even when one of its Mach-O load
# commands still names the checkout. Reject that non-relocatable bundle here,
# before a DMG can be handed to another Mac.
if otool -L "$BUNDLED_RUBY" | grep -qF "$APP_ROOT/tools/desktop-app/vendor/ruby"; then
  echo "[build-macos] packaged Ruby still references the build checkout" >&2
  exit 1
fi

echo "[build-macos] done →"
echo "  $TAURI_TARGET_DIR/release/bundle/macos/Collavre Desktop.app"
echo "Run it once via: right-click → Open (unsigned, Gatekeeper)."
