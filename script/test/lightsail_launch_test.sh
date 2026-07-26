#!/usr/bin/env bash
#
# Unit tests for the pure helpers in script/lightsail_launch.sh.
#
#   bash script/test/lightsail_launch_test.sh
#
# The launch script provisions a host and cannot be run here, so the functions
# under test are extracted from it rather than copied — a harness holding its
# own copy would keep passing after the real one drifted.
#
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SRC="${1:-$ROOT/script/lightsail_launch.sh}"
[ -f "$SRC" ] || { echo "no such script: $SRC" >&2; exit 1; }

# die() is a one-liner; the others run to the first column-1 closing brace.
eval "$(awk '
  /^die\(\) \{/ { print; next }
  /^(ensure_block|ensure_sudoers|revoke_prior_deploy_user)\(\) \{/ { f = 1 }
  f { print }
  f && /^\}/ { f = 0 }
' "$SRC")"

for fn in die ensure_block ensure_sudoers revoke_prior_deploy_user; do
  declare -F "$fn" >/dev/null || {
    echo "could not extract $fn() from $SRC — has the definition moved?" >&2
    exit 1
  }
done

fail=0
chk() {
  if [ "$2" = "$3" ]; then
    echo "  ok   $1"
  else
    echo "  FAIL $1: expected [$2] got [$3]"
    fail=1
  fi
}
# GNU stat first: BSD stat rejects -c, but GNU stat *accepts* -f as "report on
# the filesystem" and would print a block-device summary instead of a mode.
file_mode() { stat -c '%a' "$1" 2>/dev/null || stat -f '%OLp' "$1"; }
inode() { ls -i "$1" | awk '{print $1}'; }

echo "1. a re-run with a changed value replaces the block"
f=$(mktemp)
printf 'local all postgres peer\nhost all all 127.0.0.1/32 scram-sha-256\n' > "$f"
ensure_block "$f" docker "host    all    all    172.16.0.0/12    scram-sha-256"
ensure_block "$f" docker "host    all    all    10.200.0.0/16    scram-sha-256"
chk "new subnet authorized"      1 "$(grep -c '10.200.0.0/16' "$f")"
chk "old subnet revoked"         0 "$(grep -c '172.16.0.0/12' "$f")"
chk "one block, not two"         1 "$(grep -c '# BEGIN collavre:docker' "$f")"
chk "unmanaged rules untouched"  1 "$(grep -c '127.0.0.1/32' "$f")"

echo "2. the block keeps its position"
# pg_hba.conf is first-match-wins: delete-and-append would park the managed
# rule behind whatever the operator added after it.
f=$(mktemp)
printf 'A\n' > "$f"
ensure_block "$f" docker "OLD"
printf 'TRAILER\n' >> "$f"
ensure_block "$f" docker "NEW"
chk "still above TRAILER" \
  "$(printf 'A\n\n# BEGIN collavre:docker (managed by script/lightsail_launch.sh)\nNEW\n# END collavre:docker\nTRAILER')" \
  "$(cat "$f")"

echo "3. an unchanged value rewrites nothing"
f=$(mktemp)
printf 'A\n' > "$f"
ensure_block "$f" hostname "127.0.1.1 collavre"
before="$(cat "$f")"
ensure_block "$f" hostname "127.0.1.1 collavre"
chk "byte-identical" "$before" "$(cat "$f")"

echo "4. ownership and permissions survive the rewrite"
# pg_hba.conf is postgres:postgres 0640; a mv from mktemp would leave it
# root:root 0600 and PostgreSQL would fail to start.
f=$(mktemp)
printf 'A\n' > "$f"
ensure_block "$f" docker "OLD"
chmod 0640 "$f"
ino="$(inode "$f")"
ensure_block "$f" docker "NEW"
chk "mode preserved"  "640"  "$(file_mode "$f")"
chk "same inode"      "$ino" "$(inode "$f")"

echo "5. multi-line bodies are replaced whole"
f=$(mktemp)
printf 'A\n' > "$f"
ensure_block "$f" multi "$(printf 'one\ntwo')"
ensure_block "$f" multi "$(printf 'three\nfour')"
chk "new lines present" 2 "$(grep -cE '^(three|four)$' "$f")"
chk "old lines gone"    0 "$(grep -cE '^(one|two)$' "$f")"

echo "6. BEGIN with no END is refused, not guessed at"
f=$(mktemp)
printf 'A\n# BEGIN collavre:docker\nstray\nB\n' > "$f"
before="$(cat "$f")"
out="$(ensure_block "$f" docker "NEW" 2>&1)"
chk "exits non-zero"  1          "$?"
chk "file untouched"  "$before"  "$(cat "$f")"
case "$out" in
  *"no '# END collavre:docker'"*) echo "  ok   says what is wrong" ;;
  *) echo "  FAIL unhelpful message: $out"; fail=1 ;;
esac

echo "7. END before BEGIN is refused rather than truncating the file"
f=$(mktemp)
printf 'A\n# END collavre:docker\nB\n# BEGIN collavre:docker\nC\n' > "$f"
before="$(cat "$f")"
(ensure_block "$f" docker "NEW") >/dev/null 2>&1
chk "exits non-zero"  1          "$?"
chk "file untouched"  "$before"  "$(cat "$f")"

echo "8. the deploy user gets a sudoers grant sudo will actually read"
d=$(mktemp -d)
ensure_sudoers collavre "$d"
chk "one file"        1        "$(ls "$d" | wc -l | tr -d ' ')"
chk "readable name"   "90-collavre-collavre" "$(ls "$d")"
chk "mode 0440"       "440"    "$(file_mode "$d/90-collavre-collavre")"
chk "passwordless"    "collavre ALL=(ALL:ALL) NOPASSWD:ALL" "$(cat "$d/90-collavre-collavre")"
# sudo's includedir ignores any filename containing a dot, so a grant written
# for a dotted username would be silently skipped — the exact failure mode
# this whole case exists to prevent.
ensure_sudoers deploy.bot "$d"
chk "dot sanitized"   "90-collavre-deploy_bot" \
  "$(ls "$d" | grep deploy)"
chk "no dot in name"  0 "$(ls "$d" | grep -c '\.')"

echo "9. a changed APP_SSH_USER revokes the previous grant"
# Same reason ensure_block replaces in place: converge the host, do not
# accumulate. A stale NOPASSWD line is a login that outlives its purpose.
chk "old user's grant gone" 0 "$(ls "$d" | grep -c 'collavre-collavre')"
chk "only the current one"  1 "$(ls "$d" | wc -l | tr -d ' ')"
# An operator's own file is not ours to delete.
touch "$d/10-operator"
ensure_sudoers collavre "$d"
chk "operator file kept"    1 "$(ls "$d" | grep -c '^10-operator$')"

echo "10. an unparseable grant is refused, and nothing is installed"
d=$(mktemp -d)
visudo() { return 1; }   # stands in for a sudoers syntax error
out="$( (ensure_sudoers collavre "$d") 2>&1 )"
chk "exits non-zero"  1  "$?"
chk "no file written" 0  "$(ls "$d" | wc -l | tr -d ' ')"
case "$out" in
  *unparseable*) echo "  ok   says what is wrong" ;;
  *) echo "  FAIL unhelpful message: $out"; fail=1 ;;
esac
unset -f visudo

# --------------------------------------------------------------------------
# revoke_prior_deploy_user talks to the host account database, so `id` and
# `gpasswd` are stubbed. Shell functions shadow both, and `log` is captured
# rather than printed so the warning can be asserted on.
# --------------------------------------------------------------------------
ACCOUNT=""      # the only user that exists, and its groups
GROUPS_OF=""
REVOKED=""      # every gpasswd -d, as "user/group"
LOGGED=""
id() {
  case "$1" in
    -u)  [ "$2" = "$ACCOUNT" ] ;;
    -nG) [ "$2" = "$ACCOUNT" ] || return 1; printf '%s\n' "$GROUPS_OF" ;;
    *)   return 1 ;;
  esac
}
gpasswd() { REVOKED="$REVOKED $2/$3"; }
log() { LOGGED="$LOGGED $*"; }
revoke() { REVOKED=""; LOGGED=""; revoke_prior_deploy_user "$@"; }

echo "11. the deploy user a re-run replaces loses its root-equivalent access"
# Docker membership is the point: ensure_sudoers takes back the NOPASSWD file,
# and without this the replaced account keeps a shorter road to root than the
# one that was just revoked.
d=$(mktemp -d); printf 'collavre\n' > "$d/deploy_user"
ACCOUNT=collavre; GROUPS_OF="collavre docker sudo"
revoke deploybot "$d/deploy_user"
chk "docker and sudo revoked" " collavre/docker collavre/sudo" "$REVOKED"
case "$LOGGED" in
  *"can still log in"*) echo "  ok   names the account it did not delete" ;;
  *) echo "  FAIL no warning about the surviving account: $LOGGED"; fail=1 ;;
esac

echo "12. an unchanged deploy user is left exactly as it is"
# The common re-run. Revoking here would lock the operator out of their own
# host on every FORCE=1.
revoke collavre "$d/deploy_user"
chk "nothing revoked" "" "$REVOKED"
chk "nothing warned"  "" "$LOGGED"

echo "13. only the groups the user actually has are touched"
# gpasswd -d on a non-member fails; firing it anyway would put a spurious
# error in a provisioning log that operators read for real ones.
ACCOUNT=collavre; GROUPS_OF="collavre docker"
revoke deploybot "$d/deploy_user"
chk "docker only" " collavre/docker" "$REVOKED"

echo "14. a first run, an emptied marker and a deleted account are all no-ops"
d2=$(mktemp -d)
revoke collavre "$d2/deploy_user"          # no marker yet
chk "no marker"        "" "$REVOKED$LOGGED"
: > "$d2/deploy_user"
revoke collavre "$d2/deploy_user"          # marker exists but is empty
chk "empty marker"     "" "$REVOKED$LOGGED"
printf 'collavre\n' > "$d2/deploy_user"
ACCOUNT=""                                  # already deluser'd by hand
revoke deploybot "$d2/deploy_user"
chk "account is gone"  "" "$REVOKED$LOGGED"

unset -f id gpasswd log revoke

echo
if [ "$fail" = 0 ]; then echo "ALL PASS"; else echo "FAILURES"; fi
exit "$fail"
