#!/usr/bin/env bash
# Make the ruby-build output self-contained before it is copied into the .app.
# ruby-build and native extensions can record their install prefix and Homebrew
# dependencies in Mach-O load commands. Those paths only exist on the build Mac,
# so rewrite them to app-local rpaths and ship every non-system dylib that Ruby
# or an extension needs.
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
  # Source-built gems may retain their Rust/C build products below ext/*/target
  # or ports/. They are never loaded by Ruby at runtime and can contain linker
  # metadata for transient compiler artifacts, so only inspect shippable files.
  find "${MACHO_ROOTS[@]}" -type f \( -path "$RUBY_PREFIX/bin/ruby" -o -name '*.bundle' -o -name '*.dylib' \) \
    ! -path '*.dSYM/*' \
    ! -path '*/ext/*/target/*' \
    ! -path '*/ports/*' \
    -print0
}

# Preserve the absolute dependency path below lib/external rather than using a
# basename-only directory. Homebrew formulae can legitimately ship two dylibs
# with the same basename; retaining the full path prevents one from replacing
# the other during relocation.
external_destination() {
  local dependency="$1"
  printf '%s/lib/external/%s\n' "$RUBY_PREFIX" "${dependency#/}"
}

is_system_dependency() {
  case "$1" in
    /usr/lib/*|/System/Library/*|/Library/Apple/System/Library/*) return 0 ;;
    *) return 1 ;;
  esac
}

copy_external_dependency() {
  local binary="$1"
  local dependency="$2"
  local destination

  [[ "$dependency" = /* ]] || return
  is_system_dependency "$dependency" && return
  [[ "$dependency" == "$RUBY_PREFIX/"* ]] && return
  [[ "$dependency" == "$gmp_load_command" ]] && return

  destination="$(external_destination "$dependency")"
  [ -f "$destination" ] && return
  [ -f "$dependency" ] || {
    echo "non-system Ruby dependency is unavailable: $dependency (needed by $binary)" >&2
    exit 1
  }
  mkdir -p "$(dirname "$destination")"
  cp -pL "$dependency" "$destination"
  copied_external_library=true
}

# First copy the complete transitive closure of non-system dylibs. A copied
# Homebrew dylib can itself depend on another Homebrew dylib, so keep scanning
# until no new library appears in lib/external.
while :; do
  copied_external_library=false
  while IFS= read -r -d '' binary; do
    while IFS= read -r dependency; do
      copy_external_dependency "$binary" "$dependency"
    done < <(otool -L "$binary" | awk 'NR > 1 { print $1 }')
  done < <(ruby_macho_files)
  "$copied_external_library" || break
done

# Assign app-local install names before rewriting callers. The Ruby/GMP names
# remain stable for existing extensions; all other third-party libraries use
# their path beneath lib/ so colliding basenames remain distinct.
while IFS= read -r -d '' external_library; do
  external_relative_path="${external_library#"$RUBY_PREFIX/lib/"}"
  if ! otool -D "$external_library" | grep -Fxq "@rpath/$external_relative_path"; then
    install_name_tool -id "@rpath/$external_relative_path" "$external_library"
  fi
done < <(find "$RUBY_PREFIX/lib/external" -type f -name '*.dylib' -print0 2>/dev/null || true)

while IFS= read -r -d '' binary; do
  dependencies="$(otool -L "$binary" | awk 'NR > 1 { print $1 }')"
  if printf '%s\n' "$dependencies" | grep -Fxq "$RUBY_LIBRARY"; then
    install_name_tool -change "$RUBY_LIBRARY" "@rpath/$(basename "$RUBY_LIBRARY")" "$binary" >/dev/null 2>&1
  fi
  if [[ "$gmp_load_command" = /* ]] && printf '%s\n' "$dependencies" | grep -Fxq "$gmp_load_command"; then
    install_name_tool -change "$gmp_load_command" "@rpath/$gmp_name" "$binary" >/dev/null 2>&1
  fi
  while IFS= read -r dependency; do
    [[ "$dependency" = /* ]] || continue
    is_system_dependency "$dependency" && continue
    [[ "$dependency" == "$RUBY_PREFIX/"* ]] && continue
    [[ "$dependency" == "$gmp_load_command" ]] && continue
    external_relative_path="external/${dependency#/}"
    install_name_tool -change "$dependency" "@rpath/$external_relative_path" "$binary" >/dev/null 2>&1
  done <<< "$dependencies"
done < <(ruby_macho_files)

# install_name_tool invalidates the linker signatures that macOS enforces for
# arm64 processes. Re-sign every Mach-O file before executing Ruby below; the
# containing .app receives its release signature in the later packaging stage.
while IFS= read -r -d '' binary; do
  codesign --force --sign - "$binary" >/dev/null 2>&1
done < <(ruby_macho_files)

# Fail the build if any vendored Mach-O file still references a non-system
# absolute library. This catches the Ruby build prefix and all unbundled
# Homebrew dependencies, including those from standard-library extensions.
if ruby_macho_files | while IFS= read -r -d '' binary; do
  while IFS= read -r dependency; do
    [[ "$dependency" = /* ]] || continue
    is_system_dependency "$dependency" && continue
    echo "$binary still references external dylib: $dependency" >&2
    exit 1
  done < <(otool -L "$binary" | awk 'NR > 1 { print $1 }')
done; then
  :
else
  echo "vendored Ruby still contains external library paths" >&2
  exit 1
fi

echo "[relocate-ruby] Ruby runtime and native extensions are self-contained at $RUBY_PREFIX"
