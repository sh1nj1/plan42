#!/usr/bin/env bash
# Build, notarize, and publish one signed Apple-Silicon Collavre Desktop DMG.
#
# The Tauri config is the canonical desktop version. Cargo.toml is kept in sync
# because Cargo requires a package version too. This script is deliberately
# interactive: it proposes a semver bump, but never creates a version commit or
# a GitHub Release until an operator confirms the exact version.
set -euo pipefail

PROJECT_ROOT="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DESKTOP_DIR="$PROJECT_ROOT/tools/desktop-app"
TAURI_DIR="$DESKTOP_DIR/src-tauri"
TAURI_CONFIG="$TAURI_DIR/tauri.conf.json"
CARGO_TOML="$TAURI_DIR/Cargo.toml"
CARGO_LOCK="$TAURI_DIR/Cargo.lock"
TAG_PREFIX="desktop-v"
ARTIFACT_DIR="$PROJECT_ROOT/build/desktop-release"
RELEASE_ARTIFACT=""

die() {
  echo "[release-desktop] $*" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "required command is unavailable: $1"
}

check_desktop_build_prerequisites() {
  # `cargo` can be installed without its separately-installed Tauri CLI
  # subcommand. Check both build-only dependencies before making a version
  # commit, so a failed local build is never left to recover with --resume.
  require_command ruby-build
  cargo tauri --version >/dev/null 2>&1 || \
    die "Tauri CLI is unavailable; install it with: cargo install tauri-cli --version '^2'"
}

valid_semver() {
  local version="$1"
  local prerelease identifier

  [[ "$version" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-[0-9A-Za-z-]+(\.[0-9A-Za-z-]+)*)?(\+[0-9A-Za-z-]+(\.[0-9A-Za-z-]+)*)?$ ]] || return 1

  prerelease="${version%%+*}"
  [[ "$prerelease" == *-* ]] || return 0
  prerelease="${prerelease#*-}"
  IFS=. read -r -a prerelease <<< "$prerelease"
  for identifier in "${prerelease[@]}"; do
    # SemVer permits a numeric prerelease identifier of 0, but not 01, 002,
    # and so on. Cargo enforces the same rule, so reject before committing.
    [[ ! "$identifier" =~ ^[0-9]+$ || "$identifier" == "0" || "$identifier" != 0* ]] || return 1
  done
}

# Print -1, 0, or 1 when the first SemVer has lower, equal, or higher
# precedence than the second. Build metadata intentionally has no precedence.
semver_compare() {
  ruby -e '
    def parse(version)
      core_and_pre = version.split("+", 2).first
      core, prerelease = core_and_pre.split("-", 2)
      [core.split(".").map(&:to_i), prerelease&.split(".")]
    end

    def compare_identifiers(left, right)
      left.zip(right).each do |a, b|
	return -1 if a.nil?
	return 1 if b.nil?
	next if a == b

	a_numeric = /\A\d+\z/.match?(a)
	b_numeric = /\A\d+\z/.match?(b)
	return a.to_i <=> b.to_i if a_numeric && b_numeric
	return -1 if a_numeric
	return 1 if b_numeric

	return a <=> b
      end
      0
    end

    left_core, left_pre = parse(ARGV.fetch(0))
    right_core, right_pre = parse(ARGV.fetch(1))
    core_comparison = left_core <=> right_core
    if core_comparison != 0
      puts core_comparison
    elsif left_pre.nil? && right_pre.nil?
      puts 0
    elsif left_pre.nil?
      puts 1
    elsif right_pre.nil?
      puts(-1)
    else
      puts compare_identifiers(left_pre, right_pre)
    end
  ' "$1" "$2"
}

version_advances() {
  [[ "$(semver_compare "$1" "$2")" -gt 0 ]]
}

bump_version() {
  local version="$1"
  local level="$2"
  local major minor patch
  version="${version%%+*}"
  version="${version%%-*}"
  IFS=. read -r major minor patch <<< "$version"

  case "$level" in
    major) printf '%s.0.0\n' "$((major + 1))" ;;
    minor) printf '%s.%s.0\n' "$major" "$((minor + 1))" ;;
    patch) printf '%s.%s.%s\n' "$major" "$minor" "$((patch + 1))" ;;
    *) die "unknown semver bump level: $level" ;;
  esac
}

version_bump_level() {
  local range="$1"
  local messages
  messages="$(git log --format=%B "$range")"

  if grep -Eq '(^|\n)(BREAKING[ -]CHANGE:|[A-Za-z]+(\([^)]+\))?!:)' <<< "$messages"; then
    printf 'major\n'
  elif grep -Eq '(^|\n)feat(\([^)]+\))?:' <<< "$messages"; then
    printf 'minor\n'
  else
    printf 'patch\n'
  fi
}

desktop_version() {
  ruby -rjson -e 'print JSON.parse(File.read(ARGV.fetch(0))).fetch("version")' "$TAURI_CONFIG"
}

cargo_version() {
  ruby -e '
    content = File.read(ARGV.fetch(0))
    match = content.match(/\[package\][\s\S]*?^version = "([^"]+)"/)
    abort "Cargo package version is missing" unless match
    print match[1]
  ' "$CARGO_TOML"
}

cargo_lock_version() {
  ruby -e '
    content = File.read(ARGV.fetch(0))
    match = content.match(/\[\[package\]\]\s+name = "collavre-desktop"\s+version = "([^"]+)"/)
    abort "Cargo lock package version is missing" unless match
    print match[1]
  ' "$CARGO_LOCK"
}

update_versions() {
  local version="$1"
  ruby -rjson -e '
    path, version = ARGV
    config = JSON.parse(File.read(path))
    config["version"] = version
    File.write(path, JSON.pretty_generate(config) + "\n")
  ' "$TAURI_CONFIG" "$version"
  ruby -e '
    path, version = ARGV
    content = File.read(path)
    updated = content.sub(/(\[package\][\s\S]*?^version = ")[^"]+(")/) { "#{$1}#{version}#{$2}" }
    abort "Cargo package version is missing" if updated == content
    File.write(path, updated)
  ' "$CARGO_TOML" "$version"
  ruby -e '
    path, version = ARGV
    content = File.read(path)
    updated = content.sub(/(\[\[package\]\]\s+name = "collavre-desktop"\s+version = ")[^"]+(")/) { "#{$1}#{version}#{$2}" }
    abort "Cargo lock package version is missing" if updated == content
    File.write(path, updated)
  ' "$CARGO_LOCK" "$version"
}

release_notes() {
  local range="$1"
  local version="$2"

  {
    printf '# Collavre Desktop %s\n\n' "$version"
    printf '## Changes\n\n'
    git log --format='- %s (%h)' "$range"
  } > "$ARTIFACT_DIR/release-notes.md"
}

is_prerelease() {
  [[ "${1%%+*}" == *-* ]]
}

stable_version() {
  local version="${1%%+*}"
  printf '%s\n' "${version%%-*}"
}

# A prerelease can be promoted to its matching stable version without a new
# source commit, but only when the current HEAD is exactly that prerelease.
can_promote_prerelease_at_head() {
  local version="$1"
  local tag="$2"

  is_prerelease "$version" || return 1
  [[ "$tag" == "${TAG_PREFIX}${version}" ]] || return 1
  [[ "$(git rev-parse "$tag^{commit}")" == "$(git rev-parse HEAD)" ]]
}

# Git's version sort does not implement SemVer prerelease precedence (for
# example, it can order 1.0.0-rc.1 ahead of 1.0.0). Select release tags using
# the same comparator used for release-version validation instead.
previous_release_tag() {
  local excluded_tag="${1:-}" tag version latest_tag="" latest_version=""

  while IFS= read -r tag; do
    [[ "$tag" != "$excluded_tag" ]] || continue
    version="${tag#"$TAG_PREFIX"}"
    valid_semver "$version" || continue
    if [[ -z "$latest_version" ]] || version_advances "$version" "$latest_version"; then
      latest_tag="$tag"
      latest_version="$version"
    fi
  done < <(git tag --list "${TAG_PREFIX}*")

  printf '%s\n' "$latest_tag"
}

# Keep target-directory resolution identical to build-macos.sh. Cargo resolves
# a relative CARGO_TARGET_DIR from src-tauri, and the release verifier must look
# in that same location after the build completes.
normalize_tauri_target_dir() {
  local path="$1"
  local component last_index normalized_path=""
  local -a path_components=()
  local -a normalized_components=()

  [[ "$path" == /* ]] || path="$TAURI_DIR/$path"
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
  for component in "${normalized_components[@]}"; do
    normalized_path+="/$component"
  done
  printf '%s\n' "${normalized_path:-/}"
}

tauri_target_dir() {
  if [[ -n "${CARGO_TARGET_DIR:-}" ]]; then
    normalize_tauri_target_dir "$CARGO_TARGET_DIR"
  else
    printf '%s\n' "$TAURI_DIR/target"
  fi
}

write_checksum() {
  local artifact="$1"
  local checksum="$2"
  local artifact_dir artifact_name
  artifact_dir="$(dirname "$artifact")"
  artifact_name="$(basename "$artifact")"
  (
    cd "$artifact_dir"
    shasum -a 256 "$artifact_name"
  ) > "$checksum"
}

prepare_artifact_dir() {
  # build-macos stages PROJECT_ROOT into the app. Remove artifacts from a prior
  # release attempt before staging so a DMG never embeds another DMG/app.
  rm -rf "$ARTIFACT_DIR"
  mkdir -p "$ARTIFACT_DIR"
}

cleanup_mounted_dmg() {
  local mount_dir="$1"
  local attached="$2"

  if [[ "$attached" == "1" ]]; then
    hdiutil detach "$mount_dir" -quiet 2>/dev/null || true
  fi
  rmdir "$mount_dir" 2>/dev/null || true
}

release_commit_message() {
  local version="$1"
  printf 'chore(desktop): release v%s' "$version"
}

ensure_release_tag() {
  local tag="$1"
  local version="$2"
  local expected_message
  expected_message="$(release_commit_message "$version")"

  [[ "$(git log -1 --format=%s HEAD)" == "$expected_message" ]] || \
    die "resume requires HEAD to be the release commit: $expected_message"

  if git rev-parse -q --verify "refs/tags/$tag" >/dev/null; then
    [[ "$(git rev-parse "$tag^{commit}")" == "$(git rev-parse HEAD)" ]] || \
      die "existing tag $tag does not point to the release commit"
  else
    git tag -a "$tag" -m "Collavre Desktop $version"
  fi
}

reconcile_resumed_release() {
  local tag="$1"
  local version="$2"
  local expected_message remote_tag
  expected_message="$(release_commit_message "$version")"

  [[ "$(git log -1 --format=%s HEAD)" == "$expected_message" ]] || \
    die "resume requires HEAD to be the release commit: $expected_message"

  # If the release commit is already on origin/main, keep it as the immutable
  # release source even when newer commits have landed after it.
  if git merge-base --is-ancestor HEAD origin/main; then
    return
  fi

  remote_tag="$(git ls-remote --refs origin "refs/tags/$tag")"
  [[ -z "$remote_tag" ]] || \
    die "cannot rebase resumed release: $tag is already published on origin"

  # A rejected main push leaves exactly the local release commit ahead of an
  # advancing origin/main. Rebase it before rebuilding and recreate its local
  # tag so the tag always names the rebuilt release commit.
  [[ "$(git rev-list --count origin/main..HEAD)" == "1" ]] || \
    die "resume requires exactly one unpushed release commit above origin/main"
  git tag -d "$tag" >/dev/null 2>&1 || true
  git rebase origin/main
  ensure_release_tag "$tag" "$version"
}

push_release_refs() {
  local tag="$1"
  local -a refs=("refs/tags/$tag")

  # A previous attempt may already have pushed the release commit. Avoid
  # sending HEAD:main in that case: newer commits may legitimately be on main
  # while the tag and GitHub Release still need to be published.
  if ! git merge-base --is-ancestor HEAD origin/main; then
    refs=(HEAD:main "${refs[@]}")
  fi
  git push --atomic origin "${refs[@]}"
}

ensure_main_matches_origin() {
  [[ "$(git rev-parse HEAD)" == "$(git rev-parse origin/main)" ]] || \
    die "local main must exactly match origin/main before creating a release"
}

# Return 10 after a successful fast-forward so the caller can restart this
# script from the updated checkout. Bash reads function definitions at startup;
# continuing here would otherwise use stale release logic against new source.
sync_main_with_origin() {
  local head_before head_after
  head_before="$(git rev-parse HEAD)"
  git pull --ff-only origin main || return $?
  head_after="$(git rev-parse HEAD)"
  [[ "$head_before" == "$head_after" ]] || return 10
}

publish_release() {
  local tag="$1"
  local version="$2"
  local artifact="$3"
  local checksum="${artifact}.sha256"
  local -a create_args=(release create "$tag" --draft
    --title "Collavre Desktop $version"
    --notes-file "$ARTIFACT_DIR/release-notes.md"
    --verify-tag)

  is_prerelease "$version" && create_args+=(--prerelease)

  if gh release view "$tag" >/dev/null 2>&1; then
    local release_is_draft
    release_is_draft="$(gh release view "$tag" --json isDraft --jq .isDraft)"
    if [[ "$release_is_draft" == "true" ]]; then
      # A failed upload can leave a draft with only one stale asset. Replace
      # both artifacts from this build before publishing so the checksum and
      # DMG always describe the same release output.
      gh release upload "$tag" "$artifact" "$checksum" --clobber
      publish_draft_release "$tag" "$version"
    fi
    return
  fi

  # Create a draft first. A retry can then replace both assets atomically at
  # the release level before the draft is made public.
  gh "${create_args[@]}"
  gh release upload "$tag" "$artifact" "$checksum" --clobber
  publish_draft_release "$tag" "$version"
}

publish_draft_release() {
  local tag="$1"
  local version="$2"
  local -a edit_args=(release edit "$tag" --draft=false
    --title "Collavre Desktop $version"
    --notes-file "$ARTIFACT_DIR/release-notes.md")

  is_prerelease "$version" && edit_args+=(--prerelease)
  gh "${edit_args[@]}"
}

check_prerequisites() {
  [[ "$(uname -s)" == "Darwin" ]] || die "desktop releases must run on macOS"
  [[ "$(uname -m)" == "arm64" ]] || die "desktop releases must run on Apple Silicon (arm64)"
  [[ "$(git branch --show-current)" == "main" ]] || die "run from the main branch"
  [[ -z "$(git status --porcelain)" ]] || die "working tree is not clean"

  for command in git gh ruby node npm bundle cargo codesign security spctl xcrun shasum hdiutil curl tar; do
    require_command "$command"
  done
  check_desktop_build_prerequisites

  [[ -n "${APPLE_SIGNING_IDENTITY:-}" ]] || die "APPLE_SIGNING_IDENTITY is required"
  [[ -n "${APPLE_ID:-}" ]] || die "APPLE_ID is required"
  [[ -n "${APPLE_APP_SPECIFIC_PASSWORD:-}" ]] || die "APPLE_APP_SPECIFIC_PASSWORD is required"
  [[ -n "${APPLE_TEAM_ID:-}" ]] || die "APPLE_TEAM_ID is required"
  if [[ -z "${NODE_RUNTIME_DIR:-}" && ( -n "${NODE_RUNTIME_URL:-}" || -n "${NODE_RUNTIME_SHA256:-}" ) ]]; then
    [[ -n "${NODE_RUNTIME_URL:-}" && -n "${NODE_RUNTIME_SHA256:-}" ]] || die "set both NODE_RUNTIME_URL and NODE_RUNTIME_SHA256"
  fi

  security find-identity -v -p codesigning | grep -Fq "$APPLE_SIGNING_IDENTITY" || \
    die "APPLE_SIGNING_IDENTITY is not available in this keychain"
  gh auth status >/dev/null 2>&1 || die "GitHub CLI is not authenticated"
}

run_checks() {
  (
    local staging_dir="$DESKTOP_DIR/staging/app"
    local remove_staging=0
    if [[ ! -d "$staging_dir" ]]; then
      mkdir -p "$staging_dir"
      remove_staging=1
    fi
    trap 'if ((remove_staging)); then rm -rf "$DESKTOP_DIR/staging"; fi' EXIT

    local icon_source
    icon_source="$(find "$PROJECT_ROOT/public" -maxdepth 1 -type f -name 'icon-*.png' -print -quit)"
    [[ -n "$icon_source" ]] || die "desktop source icon is missing from public/"
    (
      cd "$TAURI_DIR"
      cargo tauri icon "$icon_source"
    )

    echo "[release-desktop] Running desktop Rust tests..."
    cargo test --manifest-path "$CARGO_TOML"
  )
  echo "[release-desktop] Building Rails test assets..."
  npm ci
  npm run build
  echo "[release-desktop] Running Rails tests..."
  bundle exec rake test
  bundle exec rake test:system
}

build_notarized_dmg() {
  local version="$1"
  local source_dmg app_path artifact checksum target_dir

  echo "[release-desktop] Building signed DMG..."
  target_dir="$(tauri_target_dir)"
  rm -rf "$target_dir/release/bundle/dmg"
  "$DESKTOP_DIR/scripts/build-macos.sh"

  app_path="$target_dir/release/bundle/macos/Collavre Desktop.app"
  [[ -d "$app_path" ]] || die "Tauri app bundle was not created: $app_path"
  codesign --verify --deep --strict --verbose=2 "$app_path"

  source_dmg="$(find "$target_dir/release/bundle/dmg" -maxdepth 1 -type f -name '*.dmg' -print -quit 2>/dev/null || true)"
  [[ -n "$source_dmg" ]] || die "Tauri DMG was not created"
  artifact="$ARTIFACT_DIR/Collavre-Desktop_${version}_aarch64.dmg"
  cp "$source_dmg" "$artifact"

  echo "[release-desktop] Submitting DMG to Apple notarization..."
  xcrun notarytool submit "$artifact" --wait \
    --apple-id "$APPLE_ID" \
    --password "$APPLE_APP_SPECIFIC_PASSWORD" \
    --team-id "$APPLE_TEAM_ID"
  xcrun stapler staple "$artifact"
  xcrun stapler validate "$artifact"

  local mount_dir dmg_attached=0
  mount_dir="$(mktemp -d)"
  # Validate in a subshell so its EXIT trap also runs when set -e aborts a
  # failed app-presence, signature, or Gatekeeper check.
  (
    trap 'cleanup_mounted_dmg "$mount_dir" "$dmg_attached"' EXIT
    hdiutil attach "$artifact" -readonly -nobrowse -mountpoint "$mount_dir" >/dev/null
    dmg_attached=1
    [[ -d "$mount_dir/Collavre Desktop.app" ]] || die "DMG does not contain Collavre Desktop.app"
    codesign --verify --deep --strict --verbose=2 "$mount_dir/Collavre Desktop.app"
    spctl --assess --type execute --verbose=4 "$mount_dir/Collavre Desktop.app"
  )

  checksum="$ARTIFACT_DIR/Collavre-Desktop_${version}_aarch64.dmg.sha256"
  write_checksum "$artifact" "$checksum"
  RELEASE_ARTIFACT="$artifact"
}

main() {
  cd "$PROJECT_ROOT"
  check_prerequisites

  local current_version previous_tag range bump suggested_version selected_version tag artifact resume_version="" prerelease_promotion=0
  if (($#)); then
    [[ $# -eq 2 && "$1" == "--resume" ]] || die "usage: $0 [--resume VERSION]"
    resume_version="$2"
    valid_semver "$resume_version" || die "resume version must be valid semver"
  fi

  git fetch origin main --tags
  if [[ -z "$resume_version" ]]; then
    local sync_status
    if sync_main_with_origin; then
      :
    else
      sync_status=$?
      if ((sync_status == 10)); then
	echo "[release-desktop] main advanced; restarting from the updated checkout..."
	exec bash "$PROJECT_ROOT/script/release-desktop.sh" "$@"
      fi
      return "$sync_status"
    fi
    ensure_main_matches_origin
  fi

  current_version="$(desktop_version)"
  valid_semver "$current_version" || die "Tauri version is not valid semver: $current_version"
  [[ "$current_version" == "$(cargo_version)" && "$current_version" == "$(cargo_lock_version)" ]] || \
    die "Tauri, Cargo manifest, and Cargo lock versions must match"

  if [[ -n "$resume_version" ]]; then
    selected_version="$resume_version"
    [[ "$current_version" == "$selected_version" ]] || \
      die "resume version $selected_version does not match current version $current_version"
    tag="${TAG_PREFIX}${selected_version}"
    reconcile_resumed_release "$tag" "$selected_version"
    current_version="$(desktop_version)"
    [[ "$current_version" == "$selected_version" ]] || \
      die "resume version $selected_version does not match the rebased release commit"
  fi

  previous_tag="$(previous_release_tag "${TAG_PREFIX}${resume_version}")"
  if [[ -n "$previous_tag" ]]; then
    range="$previous_tag..HEAD"
    if [[ -z "$(git log --oneline "$range")" ]]; then
      if [[ -z "$resume_version" ]] && can_promote_prerelease_at_head "$current_version" "$previous_tag"; then
      prerelease_promotion=1
      else
      die "no desktop changes since $previous_tag"
      fi
    fi
  else
    range="HEAD"
  fi
  if [[ -z "$resume_version" ]]; then
    if ((prerelease_promotion)); then
      bump="prerelease promotion"
      suggested_version="$(stable_version "$current_version")"
    else
      bump="$(version_bump_level "$range")"
      suggested_version="$(bump_version "$current_version" "$bump")"
    fi

    printf 'Current version: %s\n' "$current_version"
    printf 'Suggested version: %s (%s bump)\n' "$suggested_version" "$bump"
    read -r -p "Release version [$suggested_version]: " selected_version
    selected_version="${selected_version:-$suggested_version}"
  fi
  valid_semver "$selected_version" || die "release version must be valid semver"
  tag="${tag:-${TAG_PREFIX}${selected_version}}"
  if [[ -z "$resume_version" ]]; then
    git rev-parse -q --verify "refs/tags/$tag" >/dev/null && die "tag already exists locally: $tag"
    git ls-remote --exit-code --tags origin "refs/tags/$tag" >/dev/null 2>&1 && die "tag already exists on origin: $tag"
    if ((prerelease_promotion)); then
      [[ "$selected_version" == "$suggested_version" ]] || \
      die "unchanged prerelease source can only promote to $suggested_version"
    else
      version_advances "$selected_version" "$current_version" || \
      die "release version must advance current version $current_version"
    fi
  fi

  printf '\nBundled source commits included in this release:\n'
  git log --oneline "$range"
  if [[ -n "$resume_version" ]]; then
    read -r -p "Rebuild, notarize, and resume publishing $tag? [y/N] " confirm
  else
    read -r -p "Commit version $selected_version, build, notarize, and publish $tag? [y/N] " confirm
  fi
  [[ "$confirm" =~ ^[Yy]$ ]] || die "release cancelled"

  prepare_artifact_dir
  release_notes "$range" "$selected_version"
  if [[ -z "$resume_version" ]]; then
    update_versions "$selected_version"
    git add "$TAURI_CONFIG" "$CARGO_TOML" "$CARGO_LOCK"
    git commit -m "$(release_commit_message "$selected_version")"
  else
    ensure_release_tag "$tag" "$selected_version"
  fi

  run_checks
  build_notarized_dmg "$selected_version"
  artifact="$RELEASE_ARTIFACT"

  ensure_release_tag "$tag" "$selected_version"
  push_release_refs "$tag"
  publish_release "$tag" "$selected_version" "$artifact"

  echo "[release-desktop] Published $tag"
}

if [[ "${RELEASE_DESKTOP_LIB_ONLY:-0}" != "1" ]]; then
  main "$@"
fi
