#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RELEASE_DESKTOP_LIB_ONLY=1 source "$SCRIPT_DIR/../release-desktop.sh"

assert_equal() {
  local expected="$1"
  local actual="$2"
  [[ "$expected" == "$actual" ]] || {
    echo "expected '$expected', got '$actual'" >&2
    exit 1
  }
}

build_prerequisite_command="$(
  require_command() { printf '%s\n' "$1"; }
  cargo() { [[ "$1" == "tauri" && "$2" == "--version" ]]; }
  check_desktop_build_prerequisites
)"
assert_equal "ruby-build" "$build_prerequisite_command"
if (
  require_command() { :; }
  cargo() { return 1; }
  check_desktop_build_prerequisites
) 2>/dev/null; then
  echo "missing Tauri CLI was accepted" >&2
  exit 1
fi

valid_semver "0.1.0"
valid_semver "1.2.3-beta.1+build.8"
valid_semver "1.2.3-0+build.01"
if valid_semver "1.02.3" || valid_semver "v1.2.3" || valid_semver "1.2" || \
  valid_semver "1.2.3-01" || valid_semver "1.2.3-alpha.01"; then
  echo "invalid semver was accepted" >&2
  exit 1
fi

assert_equal "1.0.0" "$(bump_version "0.9.7" major)"
assert_equal "0.10.0" "$(bump_version "0.9.7" minor)"
assert_equal "0.9.8" "$(bump_version "0.9.7" patch)"
is_prerelease "1.2.3-beta.1"
if is_prerelease "1.2.3" || is_prerelease "1.2.3+build-1"; then
  echo "stable version was treated as a prerelease" >&2
  exit 1
fi
assert_equal "1.2.3" "$(stable_version "1.2.3-rc.1+build.7")"
assert_equal "-1" "$(semver_compare "1.2.3-alpha.2" "1.2.3-alpha.10")"
assert_equal "-1" "$(semver_compare "1.2.3-beta.1" "1.2.3")"
assert_equal "0" "$(semver_compare "1.2.3+build.1" "1.2.3+build.2")"
version_advances "1.2.3" "1.2.3-rc.1"
if version_advances "1.2.2" "1.2.3" || version_advances "1.2.3-beta.1" "1.2.3"; then
  echo "non-advancing version was accepted" >&2
  exit 1
fi

unset CARGO_TARGET_DIR
assert_equal "$TAURI_DIR/target" "$(tauri_target_dir)"
CARGO_TARGET_DIR="../release-target/./nested/.."
assert_equal "$DESKTOP_DIR/release-target" "$(tauri_target_dir)"
CARGO_TARGET_DIR="/tmp/collavre-target/../release-target"
assert_equal "/tmp/release-target" "$(tauri_target_dir)"
unset CARGO_TARGET_DIR

fixture_dir="$(mktemp -d)"
trap 'rm -rf "$fixture_dir"' EXIT
cp "$TAURI_CONFIG" "$fixture_dir/tauri.conf.json"
cp "$CARGO_TOML" "$fixture_dir/Cargo.toml"
cp "$CARGO_LOCK" "$fixture_dir/Cargo.lock"
TAURI_CONFIG="$fixture_dir/tauri.conf.json"
CARGO_TOML="$fixture_dir/Cargo.toml"
CARGO_LOCK="$fixture_dir/Cargo.lock"
update_versions "2.3.4"
assert_equal "2.3.4" "$(desktop_version)"
assert_equal "2.3.4" "$(cargo_version)"
assert_equal "2.3.4" "$(cargo_lock_version)"

repo_dir="$fixture_dir/repo"
mkdir -p "$repo_dir/tools/desktop-app"
git -C "$repo_dir" init --quiet
git -C "$repo_dir" config user.name "Release Script Test"
git -C "$repo_dir" config user.email "release-script-test@example.test"
printf 'initial\n' > "$repo_dir/tools/desktop-app/README.md"
git -C "$repo_dir" add .
git -C "$repo_dir" commit --quiet -m "chore: initial desktop"
git -C "$repo_dir" branch -M main
printf 'feature\n' >> "$repo_dir/tools/desktop-app/README.md"
git -C "$repo_dir" add .
git -C "$repo_dir" commit --quiet -m "feat(desktop): add sharing"
(
  cd "$repo_dir"
  assert_equal "minor" "$(version_bump_level HEAD)"
)
printf 'rails feature\n' > "$repo_dir/README.md"
git -C "$repo_dir" add .
git -C "$repo_dir" commit --quiet -m "feat: add bundled Rails feature"
(
  cd "$repo_dir"
  assert_equal "minor" "$(version_bump_level HEAD)"
)
printf 'breaking\n' >> "$repo_dir/tools/desktop-app/README.md"
git -C "$repo_dir" add .
git -C "$repo_dir" commit --quiet -m "feat(desktop)!: remove legacy setup"
(
  cd "$repo_dir"
  assert_equal "major" "$(version_bump_level HEAD)"
)
git -C "$repo_dir" commit --quiet --allow-empty \
  -m "fix(desktop): change desktop protocol" \
  -m "BREAKING-CHANGE: desktop protocol is incompatible with earlier releases"
(
  cd "$repo_dir"
  assert_equal "major" "$(version_bump_level HEAD~1..HEAD)"
)
git -C "$repo_dir" commit --quiet --allow-empty -m "$(release_commit_message "2.3.4")"
(
  cd "$repo_dir"
  ensure_release_tag "desktop-v2.3.4" "2.3.4"
  assert_equal "$(git rev-parse HEAD)" "$(git rev-parse desktop-v2.3.4^{commit})"
)
git -C "$repo_dir" tag -a desktop-v2.3.4-rc.1 -m "Collavre Desktop 2.3.4 RC"
(
  cd "$repo_dir"
  assert_equal "desktop-v2.3.4" "$(previous_release_tag)"
  assert_equal "desktop-v2.3.4-rc.1" "$(previous_release_tag desktop-v2.3.4)"
)

promotion_repo="$fixture_dir/promotion-repo"
git clone --quiet "$repo_dir" "$promotion_repo"
git -C "$promotion_repo" checkout --quiet main
git -C "$promotion_repo" config user.name "Release Script Test"
git -C "$promotion_repo" config user.email "release-script-test@example.test"
git -C "$promotion_repo" commit --quiet --allow-empty -m "chore(desktop): release v2.3.5-rc.1"
git -C "$promotion_repo" tag -a desktop-v2.3.5-rc.1 -m "Collavre Desktop 2.3.5 RC"
(
  cd "$promotion_repo"
  can_promote_prerelease_at_head "2.3.5-rc.1" "desktop-v2.3.5-rc.1"
  if can_promote_prerelease_at_head "2.3.5" "desktop-v2.3.5-rc.1"; then
    echo "stable release was accepted as a prerelease promotion" >&2
    exit 1
  fi
  git commit --quiet --allow-empty -m "fix: source change after release candidate"
  if can_promote_prerelease_at_head "2.3.5-rc.1" "desktop-v2.3.5-rc.1"; then
    echo "prerelease promotion was accepted after a source change" >&2
    exit 1
  fi
)

origin_dir="$fixture_dir/origin.git"
git init --bare --quiet "$origin_dir"
git -C "$repo_dir" remote add origin "$origin_dir"
git -C "$repo_dir" push --quiet origin main
git -C "$repo_dir" commit --quiet --allow-empty -m "$(release_commit_message "2.3.5")"
git -C "$repo_dir" tag -a desktop-v2.3.5 -m "Collavre Desktop 2.3.5"
remote_clone="$fixture_dir/remote-clone"
git clone --quiet --branch main "$origin_dir" "$remote_clone"
git -C "$remote_clone" config user.name "Release Script Test"
git -C "$remote_clone" config user.email "release-script-test@example.test"
printf 'remote change\n' > "$remote_clone/REMOTE_CHANGE"
git -C "$remote_clone" add REMOTE_CHANGE
git -C "$remote_clone" commit --quiet -m "fix: advance main"
git -C "$remote_clone" push --quiet origin main
(
  cd "$repo_dir"
  git fetch --quiet origin main
  reconcile_resumed_release "desktop-v2.3.5" "2.3.5"
  assert_equal "$(git rev-parse HEAD)" "$(git rev-parse desktop-v2.3.5^{commit})"
  assert_equal "$(release_commit_message "2.3.5")" "$(git log -1 --format=%s HEAD)"
  git push --quiet --atomic origin HEAD:main refs/tags/desktop-v2.3.5
)
git -C "$remote_clone" pull --quiet --ff-only origin main
printf 'later remote change\n' > "$remote_clone/LATER_REMOTE_CHANGE"
git -C "$remote_clone" add LATER_REMOTE_CHANGE
git -C "$remote_clone" commit --quiet -m "fix: advance main again"
git -C "$remote_clone" push --quiet origin main
(
  cd "$repo_dir"
  git fetch --quiet origin main
  push_release_refs "desktop-v2.3.5"
  git fetch --quiet origin main
  git merge-base --is-ancestor HEAD origin/main
)
(
  cd "$remote_clone"
  git fetch --quiet origin main
  ensure_main_matches_origin
  git commit --quiet --allow-empty -m "fix: local-only change"
  if (ensure_main_matches_origin); then
    echo "local main ahead of origin/main was accepted" >&2
    exit 1
  fi
)

dmg_detach_log="$fixture_dir/dmg-detach.log"
hdiutil() {
  printf '%s\n' "$*" >> "$dmg_detach_log"
}
mount_dir="$fixture_dir/mounted-dmg"
mkdir "$mount_dir"
cleanup_mounted_dmg "$mount_dir" 1
[[ ! -d "$mount_dir" ]] || {
  echo "mounted DMG directory was not removed" >&2
  exit 1
}
assert_equal "detach $mount_dir -quiet" "$(<"$dmg_detach_log")"

failed_mount_dir="$fixture_dir/failed-mounted-dmg"
mkdir "$failed_mount_dir"
if (
  dmg_attached=1
  trap 'cleanup_mounted_dmg "$failed_mount_dir" "$dmg_attached"' EXIT
  false
); then
  echo "failed DMG verification was accepted" >&2
  exit 1
fi
[[ ! -d "$failed_mount_dir" ]] || {
  echo "failed DMG verification did not clean up the mount directory" >&2
  exit 1
}
assert_equal "detach $failed_mount_dir -quiet" "$(tail -n 1 "$dmg_detach_log")"

artifact_dir="$fixture_dir/artifacts"
mkdir -p "$artifact_dir"
printf 'stale DMG\n' > "$artifact_dir/previous-release.dmg"
printf 'stale checksum\n' > "$artifact_dir/previous-release.dmg.sha256"
ARTIFACT_DIR="$artifact_dir"
prepare_artifact_dir
[[ -z "$(find "$artifact_dir" -mindepth 1 -print -quit)" ]] || {
  echo "previous release artifacts were not removed before staging" >&2
  exit 1
}
printf 'dmg fixture\n' > "$artifact_dir/Collavre-Desktop_2.3.4_aarch64.dmg"
write_checksum "$artifact_dir/Collavre-Desktop_2.3.4_aarch64.dmg" "$artifact_dir/Collavre-Desktop_2.3.4_aarch64.dmg.sha256"
assert_equal "Collavre-Desktop_2.3.4_aarch64.dmg" "$(awk '{print $2}' "$artifact_dir/Collavre-Desktop_2.3.4_aarch64.dmg.sha256")"
(cd "$artifact_dir" && shasum -a 256 -c "Collavre-Desktop_2.3.4_aarch64.dmg.sha256" >/dev/null)

gh_log="$fixture_dir/gh.log"
gh() {
  printf '%s\n' "$*" >> "$gh_log"
  if [[ "$1 $2 $3" == "release view desktop-v2.3.4" ]]; then
    if [[ "${4:-}" == "--json" ]]; then
      printf 'true\n'
    fi
    return 0
  fi
}
publish_release "desktop-v2.3.4" "2.3.4" "$artifact_dir/Collavre-Desktop_2.3.4_aarch64.dmg"
grep -Fqx "release upload desktop-v2.3.4 $artifact_dir/Collavre-Desktop_2.3.4_aarch64.dmg $artifact_dir/Collavre-Desktop_2.3.4_aarch64.dmg.sha256 --clobber" "$gh_log"
grep -Fqx "release edit desktop-v2.3.4 --draft=false --title Collavre Desktop 2.3.4 --notes-file $artifact_dir/release-notes.md" "$gh_log"

echo "release_desktop_test: passed"
