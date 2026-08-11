#!/usr/bin/env bash
# Make the ruby-build output self-contained before it is copied into the .app.
# ruby-build records its install prefix (and Homebrew's GMP path) in Mach-O load
# commands. Those paths only exist on the build Mac, so rewrite them to rpaths
# relative to each executable/native extension and ship the GMP dylib beside Ruby.
set -euo pipefail

RUBY_PREFIX="$1"
shift
MACHO_ROOTS=("$RUBY_PREFIX")
for root in "$@"; do
  [ -d "$root" ] || { echo "missing Mach-O root: $root" >&2; exit 1; }
  MACHO_ROOTS+=("$root")
done

[ -x "$RUBY_PREFIX/bin/ruby" ] || { echo "missing Ruby executable: $RUBY_PREFIX/bin/ruby" >&2; exit 1; }
RUBY_LIBRARY="$("$RUBY_PREFIX/bin/ruby" -rrbconfig -e 'puts File.join(RbConfig::CONFIG.fetch("libdir"), RbConfig::CONFIG.fetch("LIBRUBY_SO"))')"
[ -f "$RUBY_LIBRARY" ] || { echo "missing Ruby library: $RUBY_LIBRARY" >&2; exit 1; }

gmp_load_command="$(otool -L "$RUBY_LIBRARY" | awk '/libgmp\.[0-9]+\.dylib / { print $1; exit }')"
[ -n "$gmp_load_command" ] || { echo "Ruby was built without a GMP dylib" >&2; exit 1; }

gmp_name="$(basename "$gmp_load_command")"
gmp_destination="$RUBY_PREFIX/lib/$gmp_name"
if [[ "$gmp_load_command" = /* ]]; then
  [ -f "$gmp_load_command" ] || { echo "Ruby GMP dependency is unavailable: $gmp_load_command" >&2; exit 1; }
  cp -pL "$gmp_load_command" "$gmp_destination"
fi
[ -f "$gmp_destination" ] || { echo "missing bundled GMP library: $gmp_destination" >&2; exit 1; }

# Convert the libraries' install names first. The Ruby executable carries the
# app-local lib rpath, and dyld applies it to extensions loaded by that process.
# This avoids adding an rpath to every native gem — newly compiled extensions
# may not reserve enough Mach-O header space for another load command.
if ! otool -D "$RUBY_LIBRARY" | grep -Fxq "@rpath/$(basename "$RUBY_LIBRARY")"; then
  install_name_tool -id "@rpath/$(basename "$RUBY_LIBRARY")" "$RUBY_LIBRARY"
fi
if ! otool -D "$gmp_destination" | grep -Fxq "@rpath/$gmp_name"; then
  install_name_tool -id "@rpath/$gmp_name" "$gmp_destination"
fi

ensure_rpath() {
  local binary="$1"
  local rpath="$2"
  if ! otool -l "$binary" | grep -A2 'LC_RPATH' | grep -Fq "path $rpath "; then
    install_name_tool -add_rpath "$rpath" "$binary" >/dev/null 2>&1
  fi
}

# The executable and libruby have enough header space for their app-local rpath.
# Loaded native gems inherit this lookup path, so they do not need individual
# rpaths (which recent gem builds may not have room to add).
ensure_rpath "$RUBY_PREFIX/bin/ruby" "@loader_path/../lib"
ensure_rpath "$RUBY_LIBRARY" "@loader_path/."

ruby_macho_files() {
  find "${MACHO_ROOTS[@]}" -type f \( -path "$RUBY_PREFIX/bin/ruby" -o -name '*.bundle' -o -name '*.dylib' \) ! -path '*.dSYM/*' -print0
}

while IFS= read -r -d '' binary; do
  dependencies="$(otool -L "$binary" | awk 'NR > 1 { print $1 }')"
  if printf '%s\n' "$dependencies" | grep -Fxq "$RUBY_LIBRARY"; then
    install_name_tool -change "$RUBY_LIBRARY" "@rpath/$(basename "$RUBY_LIBRARY")" "$binary" >/dev/null 2>&1
  fi
  if [[ "$gmp_load_command" = /* ]] && printf '%s\n' "$dependencies" | grep -Fxq "$gmp_load_command"; then
    install_name_tool -change "$gmp_load_command" "@rpath/$gmp_name" "$binary" >/dev/null 2>&1
  fi
done < <(ruby_macho_files)

# install_name_tool invalidates the linker signatures that macOS enforces for
# arm64 processes. Re-sign every Mach-O file before executing Ruby below; the
# containing .app receives its release signature in the later packaging stage.
while IFS= read -r -d '' binary; do
  codesign --force --sign - "$binary" >/dev/null 2>&1
done < <(ruby_macho_files)

# Fail the build if any vendored Mach-O file still references the build host.
if ruby_macho_files | while IFS= read -r -d '' binary; do
  otool -L "$binary" | tail -n +2 | grep -F "$RUBY_PREFIX" && exit 1
  if [[ "$gmp_load_command" = /* ]] && otool -L "$binary" | tail -n +2 | grep -F "$gmp_load_command"; then
    exit 1
  fi
done; then
  :
else
  echo "vendored Ruby still contains build-machine library paths" >&2
  exit 1
fi

echo "[relocate-ruby] Ruby runtime and native extensions are self-contained at $RUBY_PREFIX"
