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

valid_semver "0.1.0"
valid_semver "1.2.3-beta.1+build.8"
if valid_semver "1.02.3" || valid_semver "v1.2.3" || valid_semver "1.2"; then
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

artifact_dir="$fixture_dir/artifacts"
mkdir -p "$artifact_dir"
printf 'dmg fixture\n' > "$artifact_dir/Collavre-Desktop_2.3.4_aarch64.dmg"
write_checksum "$artifact_dir/Collavre-Desktop_2.3.4_aarch64.dmg" "$artifact_dir/Collavre-Desktop_2.3.4_aarch64.dmg.sha256"
assert_equal "Collavre-Desktop_2.3.4_aarch64.dmg" "$(awk '{print $2}' "$artifact_dir/Collavre-Desktop_2.3.4_aarch64.dmg.sha256")"
(cd "$artifact_dir" && shasum -a 256 -c "Collavre-Desktop_2.3.4_aarch64.dmg.sha256" >/dev/null)

echo "release_desktop_test: passed"
