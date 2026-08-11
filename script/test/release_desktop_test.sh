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

artifact_dir="$fixture_dir/artifacts"
mkdir -p "$artifact_dir"
printf 'dmg fixture\n' > "$artifact_dir/Collavre-Desktop_2.3.4_aarch64.dmg"
write_checksum "$artifact_dir/Collavre-Desktop_2.3.4_aarch64.dmg" "$artifact_dir/Collavre-Desktop_2.3.4_aarch64.dmg.sha256"
assert_equal "Collavre-Desktop_2.3.4_aarch64.dmg" "$(awk '{print $2}' "$artifact_dir/Collavre-Desktop_2.3.4_aarch64.dmg.sha256")"
(cd "$artifact_dir" && shasum -a 256 -c "Collavre-Desktop_2.3.4_aarch64.dmg.sha256" >/dev/null)

echo "release_desktop_test: passed"
