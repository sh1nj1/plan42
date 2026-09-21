#!/usr/bin/env bash
# Stage the files that the desktop app needs without copying arbitrary ignored
# files from the release checkout. Generated asset outputs are intentional
# untracked inputs: Rails resolves them in production through the manifest.
set -euo pipefail

if (($# != 2)); then
  echo "usage: $0 APP_ROOT DESKTOP_DIR" >&2
  exit 64
fi

APP_ROOT="$1"
DESKTOP_DIR="$2"
STAGING="$DESKTOP_DIR/staging/app"

rm -rf "$DESKTOP_DIR/staging"
mkdir -p "$STAGING"

# Stage only Git-tracked application files. An exclusion list inevitably misses
# newly ignored files (including developer credentials), while this allowlist
# keeps release-machine state out of the signed application by construction.
git -C "$APP_ROOT" ls-files -z | \
  rsync -a --from0 --files-from=- "$APP_ROOT/" "$STAGING/"

# assets:precompile deliberately writes these two directories outside Git.
# They must be included after the tracked-file export: Propshaft serves the
# manifest/digested assets from public/assets, and the generated JavaScript is
# an asset input that must remain available to the packaged Rails app.
for generated_assets in public/assets app/assets/builds; do
  source_dir="$APP_ROOT/$generated_assets"
  destination_dir="$STAGING/$generated_assets"
  if [[ ! -d "$source_dir" ]]; then
    echo "[stage-app-tree] missing generated asset directory: $source_dir" >&2
    exit 1
  fi
  mkdir -p "$destination_dir"
  rsync -a --delete "$source_dir/" "$destination_dir/"
done

# The generated Ruby/gem tree is the sole other intentional untracked input;
# the immutable proxy is copied separately below after its runtime is bundled.
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
