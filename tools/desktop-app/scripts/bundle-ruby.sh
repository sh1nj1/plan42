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
  echo "[bundle-ruby] reusing existing vendored Ruby at $RUBY_PREFIX"
else
  echo "[bundle-ruby] building Ruby $RUBY_VERSION into $RUBY_PREFIX (this is slow)…"
  ruby-build "$RUBY_VERSION" "$RUBY_PREFIX"
fi

"$SCRIPT_DIR/relocate-ruby.sh" "$RUBY_PREFIX"

VENDORED_RUBY="$RUBY_PREFIX/bin/ruby"
export PATH="$RUBY_PREFIX/bin:$PATH"
export GEM_HOME="$VENDOR_DIR/bundle"
export GEM_PATH="$VENDOR_DIR/bundle"

echo "[bundle-ruby] $("$VENDORED_RUBY" -v)"

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
"$VENDORED_RUBY" -S bundle install --jobs 4

echo "[bundle-ruby] done. Ruby: $RUBY_PREFIX  Gems: $VENDOR_DIR/bundle"
