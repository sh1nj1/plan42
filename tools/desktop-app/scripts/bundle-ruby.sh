#!/usr/bin/env bash
# Vendor a relocatable Ruby + the app's gems into the desktop bundle.
#
# Produces:
#   tools/desktop-app/vendor/ruby/      portable Ruby (built by ruby-build)
#   tools/desktop-app/vendor/bundle/    app gems with native extensions (arm64)
#
# Native gems (sqlite3, bcrypt, nokogiri, ffi, image_processing) are compiled
# against this Ruby. libvips must be present at build time for image_processing;
# see README for bundling it into the .app.
#
# Run from the repo root (or anywhere — paths resolve from this script).
set -euo pipefail

RUBY_VERSION="${RUBY_VERSION:-3.4.4}"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DESKTOP_DIR="$(cd -P "$SCRIPT_DIR/.." && pwd)"
APP_ROOT="$(cd -P "$DESKTOP_DIR/../.." && pwd)"
VENDOR_DIR="$DESKTOP_DIR/vendor"
RUBY_PREFIX="$VENDOR_DIR/ruby"

command -v ruby-build >/dev/null 2>&1 || {
  echo "ruby-build is required (brew install ruby-build)"; exit 1;
}

mkdir -p "$VENDOR_DIR"

if [ -x "$RUBY_PREFIX/bin/ruby" ]; then
  ruby_build_is_portable="$("$RUBY_PREFIX/bin/ruby" -rrbconfig -e 'print RbConfig::CONFIG.fetch("LIBRUBY_RELATIVE") == "yes"')"
  if [ "$ruby_build_is_portable" = "true" ]; then
    echo "[bundle-ruby] reusing portable vendored Ruby at $RUBY_PREFIX"
  else
    echo "[bundle-ruby] replacing non-relocating vendored Ruby at $RUBY_PREFIX"
    rm -rf "$RUBY_PREFIX" "$VENDOR_DIR/bundle"
  fi
fi

if [ ! -x "$RUBY_PREFIX/bin/ruby" ]; then
  echo "[bundle-ruby] building Ruby $RUBY_VERSION into $RUBY_PREFIX (this is slow)…"
  RUBY_CONFIGURE_OPTS="${RUBY_CONFIGURE_OPTS:-} --enable-load-relative" ruby-build "$RUBY_VERSION" "$RUBY_PREFIX"
fi

"$SCRIPT_DIR/relocate-ruby.sh" "$RUBY_PREFIX"

VENDORED_RUBY="$RUBY_PREFIX/bin/ruby"
load_relative="$("$VENDORED_RUBY" -rrbconfig -e 'print RbConfig::CONFIG.fetch("LIBRUBY_RELATIVE")')"
[ "$load_relative" = "yes" ] || {
  echo "[bundle-ruby] Ruby was not built with --enable-load-relative" >&2
  exit 1
}
export PATH="$RUBY_PREFIX/bin:$PATH"
export GEM_HOME="$VENDOR_DIR/bundle"
export GEM_PATH="$VENDOR_DIR/bundle"

echo "[bundle-ruby] $("$VENDORED_RUBY" -v)"

# A release bundle must not retain platform gems from an earlier install: when
# source-only resolution replaces one, its stale native extension can still be
# staged and reintroduce an unavailable dependency. This directory is generated
# output, so rebuild it deterministically for every desktop package.
rm -rf "$VENDOR_DIR/bundle"
mkdir -p "$VENDOR_DIR/bundle"

# Install bundler into the vendored Ruby, then install the app's gems there.
"$VENDORED_RUBY" -S gem install bundler --no-document

cd "$APP_ROOT"
# Configure the vendored bundle via env vars, NOT `bundle config set --local`:
# --local writes desktop-only groups into the checkout's .bundle/config, which
# later dev/test/rubocop runs in the same checkout would reuse (dev+test gems
# excluded → spurious failures). Mirrors build-macos.sh and bin/desktop-server.
# Desktop runs on SQLite; skip Postgres (pg) which needs libpq at runtime.
export BUNDLE_GEMFILE="$APP_ROOT/Gemfile"
export BUNDLE_PATH="$VENDOR_DIR/bundle"
export BUNDLE_WITHOUT="development:test:production"
export BUNDLE_WITH="desktop"
# Platform gems may contain prebuilt native extensions with paths from their
# release builder. Compile them for this Ruby instead so relocation can bundle
# every dependency from the local build environment.
export BUNDLE_FORCE_RUBY_PLATFORM=true
# Nokogiri's bundled-library probe compiles Ruby 3.4 headers with `-Werror` and
# fails on current Xcode. Build it against the local system libraries instead;
# relocate-ruby.sh collects their non-system dylib dependencies into the app.
export NOKOGIRI_USE_SYSTEM_LIBRARIES="${NOKOGIRI_USE_SYSTEM_LIBRARIES:-true}"
"$VENDORED_RUBY" -S bundle install --jobs 4

# Native gem extensions are compiled after the initial Ruby relocation and keep
# the Ruby build prefix in their Mach-O load commands. Rewrite them as well so
# the staged .app never depends on the build checkout.
"$SCRIPT_DIR/relocate-ruby.sh" "$RUBY_PREFIX" "$VENDOR_DIR/bundle"

echo "[bundle-ruby] done. Ruby: $RUBY_PREFIX  Gems: $VENDOR_DIR/bundle"
