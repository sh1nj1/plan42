#!/usr/bin/env bash
#
# Unit tests for the pure helpers in script/lightsail_launch.sh, plus the
# SQLite-cutover recipe in docs/deploy_to_lightsail.md.
#
#   bash script/test/lightsail_launch_test.sh
#
# The launch script provisions a host and cannot be run here, so the functions
# under test are extracted from it rather than copied — a harness holding its
# own copy would keep passing after the real one drifted. The runbook recipe is
# extracted from the markdown for the same reason: it is a copy-paste procedure
# that touches production, so its control flow is worth testing, and testing a
# transcription of it would prove nothing.
#
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SRC="${1:-$ROOT/script/lightsail_launch.sh}"
[ -f "$SRC" ] || { echo "no such script: $SRC" >&2; exit 1; }

# die() is a one-liner; the others run to the first column-1 closing brace.
eval "$(awk '
  /^die\(\) \{/ { print; next }
  /^(ensure_block|ensure_sudoers|in_group|write_state_file|launch_record_is_complete|record_launch_settings|record_deploy_user_grant|revoke_deploy_user_access|revoke_prior_deploy_user|ensure_ufw_rule|ssh_already_allowed|ensure_ssh_rule|install_authorized_keys|install_deploy_ssh_dir|reassign_prior_db_role|refuse_superuser_db_rotation|revoke_prior_ssh_key|ensure_cluster_on_default_port|ensure_swapfile|allocate_swapfile|ensure_docker_log_caps|warn_existing_containers_keep_log_config|dedupe_authorized_keys|install_staged_authorized_keys|postgresql_conf_includes_confd|role_owns_app_objects|refuse_db_name_change|refuse_defaulted_config_change|refuse_unusable_db_identifier|refuse_unparsable_ssh_key|refuse_forced_command_ssh_key|ipv4_dotted_quad|refuse_unusable_bind_address|refuse_unusable_subnet|passwd_home|ssh_key_holder|adopt_legacy_ssh_key_marker|record_db_role_grant|reassign_one_db_role|record_ssh_key_grant|refuse_root_deploy_user|append_state_line|refuse_nologin_deploy_user|resolve_symlink_chain|stage_beside|stage_authorized_keys|verify_ssh_hardening|refuse_unusable_retention|install_managed_config|install_downloaded_file|reload_ssh_daemon)\(\) \{/ { f = 1 }
  f { print }
  f && /^\}/ { f = 0 }
' "$SRC")"

for fn in die ensure_block ensure_sudoers in_group write_state_file \
	  launch_record_is_complete record_launch_settings \
          revoke_prior_deploy_user \
          record_deploy_user_grant revoke_deploy_user_access \
          ensure_ufw_rule ssh_already_allowed ensure_ssh_rule \
          install_authorized_keys install_deploy_ssh_dir reassign_prior_db_role \
          refuse_superuser_db_rotation role_owns_app_objects revoke_prior_ssh_key \
          ensure_cluster_on_default_port ensure_swapfile allocate_swapfile \
	  ensure_docker_log_caps warn_existing_containers_keep_log_config \
	  dedupe_authorized_keys \
          install_staged_authorized_keys postgresql_conf_includes_confd \
          refuse_db_name_change refuse_defaulted_config_change \
          refuse_unusable_db_identifier refuse_unparsable_ssh_key \
          refuse_forced_command_ssh_key ipv4_dotted_quad \
          refuse_unusable_bind_address refuse_unusable_subnet \
          passwd_home ssh_key_holder \
          record_db_role_grant reassign_one_db_role record_ssh_key_grant \
          refuse_root_deploy_user append_state_line refuse_nologin_deploy_user \
          resolve_symlink_chain stage_beside stage_authorized_keys \
          verify_ssh_hardening refuse_unusable_retention \
	  install_managed_config install_downloaded_file reload_ssh_daemon \
          adopt_legacy_ssh_key_marker; do
  declare -F "$fn" >/dev/null || {
    echo "could not extract $fn() from $SRC — has the definition moved?" >&2
    exit 1
  }
done

# The suite runs unprivileged, where `chown collavre:collavre` fails on every
# host, and install_staged_authorized_keys now *declines to install* a file it
# could not hand to the deploy user rather than suppressing the error. Without a
# seam here every case that rewrites authorized_keys would exercise the refusal
# path and nothing else — the failure would look like a broken function instead
# of an unprivileged test run.
#
# Succeeding by default is the honest default because the production caller runs
# as root against an account it has just created. The cases that need the
# failure make it fail explicitly (CHOWN_FAILS), which is the one place where
# what is under test is the refusal itself.
CHOWN_FAILS=0
chown() { [ "$CHOWN_FAILS" = 0 ]; }

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
# pg_hba.conf is postgres:postgres 0640; a staging file left at mktemp's
# root:root 0600 would stop PostgreSQL reading it back.
#
# The inode deliberately changes. It used not to: the block was copied through
# the live inode with `cat "$tmp" > "$file"` precisely to keep the mode, and
# that is what made the rewrite non-atomic — see 4a. Preserving the mode is the
# invariant; preserving the inode was the mechanism, and asserting the
# mechanism here is what would forbid the fix.
f=$(mktemp)
printf 'A\n' > "$f"
ensure_block "$f" docker "OLD"
chmod 0640 "$f"
ino="$(inode "$f")"
ensure_block "$f" docker "NEW"
chk "mode preserved"  "640"  "$(file_mode "$f")"
if [ "$ino" = "$(inode "$f")" ]; then
  echo "  FAIL rewritten through the live inode rather than renamed into place"; fail=1
else
  echo "  ok   renamed into place, so the live path is never a partial file"
fi

echo "4a. a copy that fails does not leave the live file truncated"
# The previous form ended in `cat "$tmp" > "$file"`, which truncates the live
# path when the redirection opens — so a run that died during the copy left the
# file holding a prefix of itself. Measured on that revision by sampling the
# live path during the rewrite of a 10MB pg_hba.conf: 0 bytes. This helper
# rewrites /etc/fstab, /etc/hosts, postgresql.conf and pg_hba.conf, and each
# fails differently: an empty pg_hba.conf refuses every connection, a truncated
# fstab loses mounts, and a block left without its END marker makes the *next*
# run die on "repair or delete it by hand" instead of converging.
#
# Injected rather than sampled or killed. Both of those are races: measured at
# ~1MB the sampling loop missed the window on 3 runs in 8, and a flaky control
# is worse than none. Shadowing the copy is deterministic and models exactly
# the failure — a copy that does not complete — in the same way cases 44-46
# shadow grep and mktemp.
f=$(mktemp)
{ printf '# BEGIN collavre:docker\nOLD\n# END collavre:docker\n'
  printf 'operator-line\n'; } > "$f"
# shellcheck disable=SC2329  # shadows cat for ensure_block only
cat() { return 1; }
ensure_block "$f" docker "NEW" || true
unset -f cat
chk "the operator's line survived"  1 "$(grep -cxF 'operator-line' "$f")"
chk "the END marker survived"       1 "$(grep -cxF '# END collavre:docker' "$f")"
chk "the file is not empty"         1 "$([ -s "$f" ] && echo 1 || echo 0)"
chk "no staging file left beside it" 0 \
  "$(find "$(dirname "$f")" -maxdepth 1 -name "$(basename "$f").collavre.*" | wc -l | tr -d ' ')"

echo "4b. a symlinked target is written through, not replaced by the rename"
# The regression the rename introduces and the copy did not have. rename(2)
# does not follow symlinks: pointed at a symlinked /etc/hosts — which is how a
# host running systemd-resolved or a config-management tool is often laid out —
# an unresolved `mv` swaps the link itself for a regular file, and the real file
# every other reader still resolves to keeps whatever it held before. Measured
# on the same helper with the resolution removed:
#
#   link is a symlink afterwards   no
#   real file                      OLD      <- the run reported success
#   link (now a regular file)      NEW
#
# So the block converges on a file nothing reads, and the next run reads its own
# managed block back out of it and reports converged again. The append branch
# writes *through* the link, so this is also what keeps the first run and every
# later one meaning the same file.
d=$(mktemp -d)
printf 'A\n' > "$d/real"
ln -s "$d/real" "$d/link"
ensure_block "$d/link" docker "OLD"
ensure_block "$d/link" docker "NEW"
chk "still a symlink"              "yes" "$([ -L "$d/link" ] && echo yes || echo no)"
chk "the real file has the block"  1 "$(grep -cxF 'NEW' "$d/real")"
chk "and no second regular file"   1 "$(find "$d" -maxdepth 1 -type f | wc -l | tr -d ' ')"
# Relative targets resolve against the link's own directory, not $PWD — the
# form /etc/postgresql/17/main/pg_hba.conf takes when a tool points it at a
# sibling. Resolving against $PWD would create the file in the harness's cwd.
mkdir -p "$d/sub"
printf 'A\n' > "$d/sub/rel-real"
ln -s rel-real "$d/sub/rel-link"
ensure_block "$d/sub/rel-link" docker "OLD"
ensure_block "$d/sub/rel-link" docker "NEW"
chk "relative link resolved beside itself" 1 "$(grep -cxF 'NEW' "$d/sub/rel-real")"
chk "nothing created in the cwd"           0 "$(find . -maxdepth 1 -name 'rel-real' | wc -l | tr -d ' ')"
# A loop must refuse rather than spin: this runs as root over /etc.
ln -s "$d/loop-b" "$d/loop-a"
ln -s "$d/loop-a" "$d/loop-b"
out="$( (ensure_block "$d/loop-a" docker "NEW") 2>&1 )"
chk "a symlink loop is refused" 1 "$?"
case "$out" in
  *"too deep to follow"*) echo "  ok   says what it will not chase" ;;
  *) echo "  FAIL unhelpful: $out"; fail=1 ;;
esac

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
# revoke_prior_deploy_user talks to the host account database, so `id`,
# `gpasswd`, `usermod` and `groupadd` are stubbed. Shell functions shadow them,
# and `log` is captured rather than printed so the warning can be asserted on.
#
# The stubs MUTATE $GROUPS_OF rather than only recording the call, because the
# function now re-reads membership to decide what it claims. A stub that always
# reported success would make the "could not revoke" path untestable — which is
# the path that matters.
#
# GROUPS_OF is "primary supplementary...", matching `id -nG` output order, so
# the primary group is its first word. gpasswd refuses primary groups with
# exit 3 exactly as the real one does; verified on ubuntu:24.04.
# --------------------------------------------------------------------------
ACCOUNT=""      # the only user that exists, and its groups
GROUPS_OF=""
ALSO_SUPP=""    # groups held via /etc/group *as well as* by being primary; a
                # state `id -nG` cannot show, because it prints each group once
REVOKED=""      # every gpasswd -d, as "user/group"
USERMOD=""      # every usermod -g, as "user:group"
LOGGED=""
# shellcheck disable=SC2329  # called by the gpasswd/usermod stubs below
supp_holds() { case " $ALSO_SUPP " in *" $1 "*) return 0 ;; *) return 1 ;; esac; }
# shellcheck disable=SC2329  # called by the gpasswd/usermod stubs below
drop_word() { printf '%s\n' "$2" | tr ' ' '\n' | grep -vxF "$1" | tr '\n' ' ' | sed 's/ $//'; }
id() {
  case "$1" in
    -u)  [ "$2" = "$ACCOUNT" ] ;;
    -nG) [ "$2" = "$ACCOUNT" ] || return 1; printf '%s\n' "$GROUPS_OF" ;;
    -gn) [ "$2" = "$ACCOUNT" ] || return 1; printf '%s\n' "${GROUPS_OF%% *}" ;;
    *)   return 1 ;;
  esac
}
gpasswd() {
  REVOKED="$REVOKED $2/$3"
  # /etc/group only: a purely primary membership lives in /etc/passwd and is
  # refused with exit 3. An /etc/group entry is removed even when the same group
  # is also the primary one — verified on ubuntu:24.04.
  if supp_holds "$3"; then
    ALSO_SUPP="$(drop_word "$3" "$ALSO_SUPP")"
  elif [ "${GROUPS_OF%% *}" = "$3" ]; then
    return 3
  fi
  GROUPS_OF="$(drop_word "$3" "$GROUPS_OF")"
}
# Named so the cases below that swap usermod out can restore it by reference
# rather than by re-typing it — two copies would drift, and the copy is what
# the "does not take" and "retry" cases depend on being faithful.
# shellcheck disable=SC2329  # called by the usermod stub, and by the cases that restore it
usermod_host() {   # usermod -g <group> <user>
  USERMOD="$USERMOD $3:$2"
  supp="$(printf '%s\n' "$GROUPS_OF" | cut -s -d' ' -f2-)"; GROUPS_OF="$2${supp:+ $supp}"
  # moving the primary group does not touch /etc/group, so anything held there
  # survives and `id -nG` goes on reporting it
  for g in $ALSO_SUPP; do
    case " $GROUPS_OF " in *" $g "*) ;; *) GROUPS_OF="$GROUPS_OF $g" ;; esac
  done
}
usermod() { usermod_host "$@"; }
groupadd() { :; }
log() { LOGGED="$LOGGED $*"; }
revoke() { REVOKED=""; USERMOD=""; LOGGED=""; revoke_prior_deploy_user "$@"; }

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

echo "15. a PRIMARY docker group is taken back too, not just a supplementary one"
# gpasswd cannot remove a primary group — it exits 3 while `id -nG` goes on
# reporting the membership. An account made with `useradd -g docker` would
# otherwise keep a root shell through the docker socket after a rotation that
# reported success.
d3=$(mktemp -d); printf 'legacy\n' > "$d3/deploy_user"
ACCOUNT=legacy; GROUPS_OF="docker sudo"      # docker is PRIMARY here
revoke deploybot "$d3/deploy_user"
chk "no longer in docker" 0 "$(printf '%s\n' "$GROUPS_OF" | tr ' ' '\n' | grep -cxF docker)"
chk "primary group moved to its own" " legacy:legacy" "$USERMOD"
chk "sudo revoked by gpasswd"        " legacy/sudo"   "$REVOKED"
case "$LOGGED" in
  *"could NOT revoke"*) echo "  FAIL claimed failure on a revocation that worked: $LOGGED"; fail=1 ;;
  *"can still log in"*) echo "  ok   reports the account as revoked but still present" ;;
  *) echo "  FAIL no warning at all: $LOGGED"; fail=1 ;;
esac
chk "marker advanced" "deploybot" "$(cat "$d3/deploy_user")"

echo "16. a group that is BOTH primary and an /etc/group entry is fully revoked"
# `useradd -g docker` then `gpasswd -a` leaves docker in /etc/passwd AND in
# /etc/group. Moving the primary group takes back only the first, so the
# account keeps the docker socket — and `id -nG` prints docker once either way,
# which is why the previous case cannot catch this one. Reproduced on
# ubuntu:24.04 before this test was written.
d3b=$(mktemp -d); printf 'legacy\n' > "$d3b/deploy_user"
ACCOUNT=legacy; GROUPS_OF="docker"; ALSO_SUPP="docker"
revoke deploybot "$d3b/deploy_user"
chk "no longer in docker" 0 "$(printf '%s\n' "$GROUPS_OF" | tr ' ' '\n' | grep -cxF docker)"
chk "the primary group moved"        " legacy:legacy" "$USERMOD"
chk "and the /etc/group entry went too" " legacy/docker" "$REVOKED"
case "$LOGGED" in
  *"could NOT revoke"*) echo "  FAIL still holds docker, or claims it does: $LOGGED"; fail=1 ;;
  *"can still log in"*) echo "  ok   revoked in one run, not two" ;;
  *) echo "  FAIL no warning at all: $LOGGED"; fail=1 ;;
esac
chk "marker advanced" "deploybot" "$(cat "$d3b/deploy_user")"
ALSO_SUPP=""

echo "17. a revocation that does not take is reported, not claimed as done"
# The failure this replaces: gpasswd exits nonzero, the && swallows it, and the
# unconditional warning tells the operator the account lost root when it did not.
d4=$(mktemp -d); printf 'legacy\n' > "$d4/deploy_user"
ACCOUNT=legacy; GROUPS_OF="docker"
usermod() { USERMOD="$USERMOD $3:$2"; }      # the host refuses the change
revoke deploybot "$d4/deploy_user"
case "$LOGGED" in
  *"could NOT revoke docker"*) echo "  ok   says which group it failed to take back" ;;
  *) echo "  FAIL silent or wrongly reassuring: $LOGGED"; fail=1 ;;
esac
case "$LOGGED" in
  *"no longer in docker or sudo"*) echo "  FAIL still claims the access is gone"; fail=1 ;;
  *) echo "  ok   does not claim the access is gone" ;;
esac

echo "18. and the account it could not strip stays queued for the next run"
# The retry lives in the set rather than in the single-name marker. Pinning that
# marker to the unrevoked account — what an earlier revision did — bought the
# retry at the price of the host misreporting who its deploy user is, and it is
# what case 18a shows losing an account outright on the second rotation.
chk "still queued for revocation" 1 \
  "$(grep -cxF legacy "$d4/deploy_users")"
chk "the marker names the account in use" "deploybot" "$(cat "$d4/deploy_user")"
usermod() { usermod_host "$@"; }             # the host is healthy again
revoke deploybot "$d4/deploy_user"           # the retry, on a healthy host
chk "the retry revokes it"     0 "$(printf '%s\n' "$GROUPS_OF" | tr ' ' '\n' | grep -cxF docker)"
chk "and it leaves the queue" 0 "$(grep -cxF legacy "$d4/deploy_users")"
chk "while the marker still names the account in use" "deploybot" "$(cat "$d4/deploy_user")"

unset -f id gpasswd usermod usermod_host groupadd log revoke supp_holds drop_word

# --------------------------------------------------------------------------
# One name cannot describe a host that has rotated twice, so the cases below
# need more than one account on the host. The model is a directory holding one
# file per account, whose contents are what `id -nG` would print; FAIL_REVOKE
# names the accounts whose `gpasswd -d` does nothing, which is how the sequence
# that matters is reached.
#
# grant() is what the script does at its two grant sites (step 3's `usermod -aG
# sudo` and step 4's `usermod -aG docker`), so a case can place them relative to
# the revocation the same way the script does — which is the whole point here,
# since the second of these cases is about an interruption between them.
# --------------------------------------------------------------------------
HOSTDB=""; FAIL_REVOKE=""
id() {
  case "$1" in
    -u)  [ -f "$HOSTDB/$2" ] ;;
    -nG) [ -f "$HOSTDB/$2" ] || return 1; cat "$HOSTDB/$2" ;;
    -gn) [ -f "$HOSTDB/$2" ] || return 1; cut -d' ' -f1 "$HOSTDB/$2" ;;
    *)   return 1 ;;
  esac
}
gpasswd() {   # gpasswd -d <user> <group>
  case " $FAIL_REVOKE " in *" $2 "*) return 1 ;; esac
  tr ' ' '\n' < "$HOSTDB/$2" | grep -vxF "$3" | tr '\n' ' ' |
    sed 's/ *$//' > "$HOSTDB/$2.next"
  mv "$HOSTDB/$2.next" "$HOSTDB/$2"
}
# shellcheck disable=SC2329  # called through the extracted function
usermod() { :; }
# shellcheck disable=SC2329
groupadd() { :; }
log() { :; }
grant() { printf '%s docker sudo' "$1" > "$HOSTDB/$1"; }
holds() { tr ' ' '\n' < "$HOSTDB/$1" | grep -cxF "$2"; }

# The negative control is the previous revision's *marker discipline* rather
# than a copy of its revocation body: one name in the file, advanced only when
# the account it names comes back clean. The body is unchanged and is called
# here, so the control isolates the one thing that did change — and copying
# fifty lines that still exist would drift from them rather than test against
# them.
revoke_single_marker() {
  local current="$1" f="$2" prior
  [ -f "$f" ] || { printf '%s\n' "$current" > "$f"; return 0; }
  prior="$(cat "$f")"
  if [ -z "$prior" ] || [ "$prior" = "$current" ] ||
     ! id -u "$prior" >/dev/null 2>&1; then
    printf '%s\n' "$current" > "$f"; return 0
  fi
  revoke_deploy_user_access "$prior" "$current" || return 0   # marker pinned
  printf '%s\n' "$current" > "$f"
}

echo "18a. a rotation whose revocation failed does not lose the NEXT account"
# A -> B with the revocation of A failing, then B -> C. The earlier revision
# retried A on the third run and advanced its one marker straight to C, so B
# went on holding docker and sudo with nothing on the host naming it.
HOSTDB=$(mktemp -d); d5=$(mktemp -d)
grant collavre; printf 'collavre\n' > "$d5/deploy_user"
FAIL_REVOKE=collavre; grant deploybot
revoke_prior_deploy_user deploybot "$d5/deploy_user"
FAIL_REVOKE=""; grant ci
revoke_prior_deploy_user ci "$d5/deploy_user"
chk "the account in between lost docker" 0 "$(holds deploybot docker)"
chk "and sudo"                           0 "$(holds deploybot sudo)"
chk "the one that failed was retried"    0 "$(holds collavre docker)"
# The account in use stays queued on purpose — it holds both groups, and the
# run that replaces it is the one that takes them back. So the assertion is that
# nothing ELSE is left in it, which is also what keeps the queue from growing by
# one name per rotation forever.
chk "nothing but the account in use is queued" "ci" \
  "$(tr '\n' ' ' < "$d5/deploy_users" | sed 's/ *$//')"

# The control. Same host, same sequence, previous marker discipline.
HOSTDB=$(mktemp -d); d6=$(mktemp -d)
grant collavre; printf 'collavre\n' > "$d6/deploy_user"
FAIL_REVOKE=collavre; grant deploybot
revoke_single_marker deploybot "$d6/deploy_user"
FAIL_REVOKE=""; grant ci
revoke_single_marker ci "$d6/deploy_user"
chk "the previous form left it holding docker" 1 "$(holds deploybot docker)"
chk "with the marker naming neither it nor its predecessor" "ci" \
  "$(cat "$d6/deploy_user")"

echo "18b. an interrupted rotation does not hide the account it already granted"
# No failure anywhere. The grants are at step 3 and step 4 and the revocation is
# at the end of step 4, so the window is the whole Docker install — an apt run
# on a 512MB instance. Recording the grant BEFORE it is what closes this; a
# record written after the revocation cannot describe a run that never reached
# it.
HOSTDB=$(mktemp -d); d7=$(mktemp -d)
grant collavre; printf 'collavre\n' > "$d7/deploy_user"
record_deploy_user_grant deploybot "$d7/deploy_users" "$d7/deploy_user"
grant deploybot                              # ... and the run dies here
grant ci
record_deploy_user_grant ci "$d7/deploy_users" "$d7/deploy_user"
revoke_prior_deploy_user ci "$d7/deploy_user"
chk "the interrupted run's account lost docker" 0 "$(holds deploybot docker)"
chk "and sudo"                                  0 "$(holds deploybot sudo)"
chk "so did the one before it"                  0 "$(holds collavre docker)"

echo "18c. a host provisioned before the queue existed is seeded from its marker"
# The upgrade path. Starting empty would begin the fix for forgetting accounts
# by forgetting the one account the old revision did record — and that account
# is the one most likely to be unrevoked, since a clean rotation is why the
# marker would have moved on.
HOSTDB=$(mktemp -d); d8=$(mktemp -d)
grant collavre; printf 'collavre\n' > "$d8/deploy_user"   # no deploy_users file
grant deploybot
revoke_prior_deploy_user deploybot "$d8/deploy_user"
chk "the legacy predecessor was found and stripped" 0 "$(holds collavre docker)"
chk "and the queue now holds only the account in use" "ci_absent deploybot" \
  "ci_absent $(tr '\n' ' ' < "$d8/deploy_users" | sed 's/ *$//')"

echo "18d. a queue rewrite that cannot complete leaves the previous queue intact"
# `> "$set_file"` truncates when the redirection opens and only then writes, so
# a write that fails in between leaves the file existing and EMPTY — which is
# indistinguishable from a host with nothing left to revoke. `ulimit -f 0`
# stands in for a full disk: creating the file is allowed, writing to it is not.
d9=$(mktemp -d)
printf 'deploybot\nci\n' > "$d9/deploy_users"
# The redirect is on the GROUP, not on the subshell. SIGXFSZ kills the child,
# and "Filesize limit exceeded" is printed by the parent that reaps it, to the
# parent's stderr — so `( ... ) 2>/dev/null` silences the child and leaves the
# report in the suite's output.
{ ( ulimit -f 0; write_state_file "$d9/deploy_users" 'ci
' ); } 2>/dev/null
chk "the queue still names the unrevoked account" "deploybot ci" \
  "$(tr '\n' ' ' < "$d9/deploy_users" | sed 's/ *$//')"

# The control: the same failure against the previous form. Only the write is
# swapped — the surrounding function is unchanged and is what both forms run.
d10=$(mktemp -d)
printf 'deploybot\nci\n' > "$d10/deploy_users"
printf 'ci\n' > "$d10/deploy_user"
{ ( ulimit -f 0; printf '%s' 'ci
' > "$d10/deploy_users" ); } 2>/dev/null
chk "the previous form emptied it" "" \
  "$(tr '\n' ' ' < "$d10/deploy_users" | sed 's/ *$//')"
# And nothing brings it back. Seeding is guarded on the file being ABSENT, and
# this one exists; the single-name marker names the account in use, so it could
# not have named deploybot even if the seeding did run. The queue was the only
# record of it, which is the whole reason the queue exists.
record_deploy_user_grant ci "$d10/deploy_users" "$d10/deploy_user"
chk "and the next run cannot bring it back" "ci" \
  "$(tr '\n' ' ' < "$d10/deploy_users" | sed 's/ *$//')"

echo "18e. a seeding that cannot complete is retried, not retired"
# The upgrade path runs once per host — its guard is `! -f`, so whatever state
# the file is left in is the state it keeps. The append at the end of the
# function would create the file, so a run that could not write the seed has to
# stop before reaching it, or it retires the upgrade on the one host that still
# needs it.
d11=$(mktemp -d)
printf 'legacy\n' > "$d11/deploy_user"          # provisioned before the queue
mktemp() { return 1; }                          # no staging file can be made
record_deploy_user_grant deploybot "$d11/deploy_users" "$d11/deploy_user"; rc=$?
unset -f mktemp
chk "it reports that it could not record" 1 "$rc"
chk "and leaves no file behind to retire the upgrade" absent \
  "$([ -e "$d11/deploy_users" ] && echo present || echo absent)"
record_deploy_user_grant deploybot "$d11/deploy_users" "$d11/deploy_user"
chk "so a later run still finds the predecessor" "legacy deploybot" \
  "$(tr '\n' ' ' < "$d11/deploy_users" | sed 's/ *$//')"

# The control: the previous form created the file on its way to failing, and
# `|| true` meant nothing anywhere said so.
d12=$(mktemp -d); printf 'legacy\n' > "$d12/deploy_user"
{ ( ulimit -f 0; grep -v '^[[:space:]]*$' "$d12/deploy_user" > "$d12/deploy_users" || true ); } 2>/dev/null
chk "the previous form left the file existing" present \
  "$([ -e "$d12/deploy_users" ] && echo present || echo absent)"
grep -qxF deploybot "$d12/deploy_users" 2>/dev/null ||
  printf '%s\n' deploybot >> "$d12/deploy_users"
chk "and the legacy predecessor is absent for good" "deploybot" \
  "$(tr '\n' ' ' < "$d12/deploy_users" | sed 's/ *$//')"

unset -f id gpasswd usermod groupadd log grant holds revoke_single_marker

# --------------------------------------------------------------------------
# The firewall helpers shell out to ufw, so it is stubbed: every invocation is
# recorded, and STATUS stands in for what `ufw status` would print.
# --------------------------------------------------------------------------
UFW_CALLS=""
STATUS=""
LOGGED=""
ufw() {
  if [ "$1" = status ]; then printf '%s\n' "$STATUS"; return 0; fi
  UFW_CALLS="$UFW_CALLS|$*"
}
log() { LOGGED="$LOGGED $*"; }

echo "19. the postgres rule is added once and recorded"
d=$(mktemp -d)
UFW_CALLS=""
ensure_ufw_rule postgres "allow from 172.17.0.0/16 to 172.17.0.1 port 5432 proto tcp" \
  "$d/ufw_postgres"
chk "rule added" "|allow from 172.17.0.0/16 to 172.17.0.1 port 5432 proto tcp" "$UFW_CALLS"
chk "recorded"   "allow from 172.17.0.0/16 to 172.17.0.1 port 5432 proto tcp" \
  "$(cat "$d/ufw_postgres")"

echo "20. an unchanged rule deletes nothing"
# The common re-run. ufw skips re-adding an identical rule itself, so the only
# thing that must not happen here is a delete.
UFW_CALLS=""; LOGGED=""
ensure_ufw_rule postgres "allow from 172.17.0.0/16 to 172.17.0.1 port 5432 proto tcp" \
  "$d/ufw_postgres"
chk "no delete" 0 "$(printf '%s' "$UFW_CALLS" | grep -c delete)"

echo "21. a changed rule withdraws the old one instead of accumulating"
# Without this, moving DB_BIND_ADDRESS or DOCKER_SUBNETS would leave the
# previous subnet reaching 5432 for the life of the host.
UFW_CALLS=""; LOGGED=""
ensure_ufw_rule postgres "allow from 10.200.0.0/16 to 172.18.0.1 port 5432 proto tcp" \
  "$d/ufw_postgres"
chk "old rule deleted" \
  "|delete allow from 172.17.0.0/16 to 172.17.0.1 port 5432 proto tcp" \
  "$(printf '%s' "$UFW_CALLS" | grep -o '|delete[^|]*')"
chk "new rule added" 1 "$(printf '%s' "$UFW_CALLS" | grep -c '|allow from 10.200.0.0/16')"
chk "state advanced" "allow from 10.200.0.0/16 to 172.18.0.1 port 5432 proto tcp" \
  "$(cat "$d/ufw_postgres")"

echo "22. unrelated operator rules are never touched"
# The whole reason `ufw reset` is gone: a re-run must not disturb a VPN,
# monitoring or allowlist rule this script knows nothing about.
chk "only our own rule deleted" 1 "$(printf '%s' "$UFW_CALLS" | grep -c delete)"
chk "no reset"                  0 "$(printf '%s' "$UFW_CALLS" | grep -c reset)"

echo "23. SSH already allowed is detected in every form ufw prints it"
# Only IPv4 counts — see case 25a. ufw writes the "(v6)" line alongside its IPv4
# twin and deletes them together, so the dual-stack pair is what a real host
# carries; the tagged line is never alone, and here it must not be what decides.
for s in "22/tcp                     ALLOW       Anywhere" \
         "22                         ALLOW IN    Anywhere" \
         "OpenSSH                    ALLOW       Anywhere" \
         "22/tcp                     ALLOW IN    203.0.113.4" \
         "22/tcp                     LIMIT       203.0.113.9" \
         "22/tcp                     LIMIT IN    Anywhere" \
         "10.1.2.3 22/tcp            ALLOW       203.0.113.9" \
         "10.1.2.3 22/tcp            LIMIT       203.0.113.9" \
         "22/tcp                     ALLOW       Anywhere                   # ssh: admin only" \
         "22/tcp                     ALLOW       203.0.113.4                # ops: jump box" \
         "22/tcp                     ALLOW       Anywhere
22/tcp (v6)                ALLOW       Anywhere (v6)" \
         "22/tcp                     ALLOW       203.0.113.4
22/tcp                     ALLOW       2001:db8::9"; do
  STATUS="$s"
  ssh_already_allowed
  chk "detected: ${s%%
*}" 0 "$?"
done

echo "23a. a rule that is not inbound does not count as authorization"
# `ufw status` puts the direction in the action column only when it is *not*
# inbound — there is no "ALLOW IN" in this output, so an inbound rule and an
# outbound one differ by a word the pattern above did not read. Every line below
# is real ufw output from ubuntu:24.04, one `ufw status` per rule shape, not a
# rendering written from the man page.
#
# The consequence is the worst outcome in this script rather than a missed
# optimisation: `ufw default deny incoming` is applied and ufw enabled a few
# steps later, so a host whose only port-22 rule is outbound has SSH read as
# authorized, no inbound rule added, and the firewall turned on — locking out
# the operator who is running this over SSH at the time.
for s in "22/tcp                     ALLOW OUT   Anywhere" \
         "OpenSSH                    ALLOW OUT   Anywhere" \
         "22/tcp                     ALLOW FWD   Anywhere" \
         "80/tcp                     ALLOW       Anywhere

22/tcp                     ALLOW OUT   Anywhere"; do
  STATUS="$s"
  ssh_already_allowed
  chk "not authorization: ${s%%
*}" 1 "$?"
done
# The controls, and they are what rules out a stricter pattern in favour of a
# filter: the four shapes an operator legitimately has must still be left alone.
# Getting these wrong re-adds a blanket `allow OpenSSH` over a rule someone
# narrowed on purpose, which is the failure case 24 exists for.
for s in "22/tcp                     ALLOW       Anywhere" \
         "OpenSSH                    ALLOW       Anywhere" \
         "22/tcp                     LIMIT       Anywhere" \
         "22/tcp                     ALLOW       203.0.113.7"; do
  STATUS="$s"
  ssh_already_allowed
  chk "still authorization: ${s%%
*}" 0 "$?"
done

echo "24. a narrowed SSH rule survives the re-run that finds it"
# The rule an operator most plausibly tightens by hand. Re-adding the blanket
# `allow OpenSSH` on top would reopen 22 to the internet and look like a no-op.
#
# LIMIT is here because it is what ufw's own documentation recommends for SSH:
# reading only ALLOW meant a rate-limited, source-restricted rule was reported
# as "nothing authorizes SSH", and the blanket rule went in beside it.
#
# The destination-qualified forms are the same defect one step further out: the
# port is not at the start of the line, so a predicate anchored on the port
# reports "nothing authorizes SSH" for a rule that pins 22 to one interface.
for s in "22/tcp                     ALLOW IN    203.0.113.4" \
         "22/tcp                     LIMIT       203.0.113.9" \
         "10.1.2.3 22/tcp            ALLOW       203.0.113.9" \
         "10.1.2.3 22/tcp            LIMIT       203.0.113.9"; do
  STATUS="$s"
  UFW_CALLS=""
  ensure_ssh_rule
  chk "blanket rule not added over [$s]" "" "$UFW_CALLS"
done

echo "25. no SSH rule at all means one is added, never assumed"
# Failing the other way enables a deny-by-default firewall on a host with no
# way back in, so every uncertain status must land here.
#
# The last three guard the optional leading token that makes the
# destination-qualified forms match: it must not swallow a different port, nor
# turn a host address that merely begins with 22 into an SSH rule. The
# all-ports rule is a decision, not an oversight — it permits 22 from that
# source, but its source is as often a trusted service host as the operator's
# own machine, and reading it as "SSH is handled" would enable a
# deny-by-default firewall on a box with no remaining way in.
for s in "Status: inactive" \
         "80/tcp                     ALLOW       Anywhere" \
         "2222/tcp                   ALLOW       Anywhere" \
         "22/tcp                     DENY        Anywhere" \
         "10.1.2.3 2222/tcp          ALLOW       203.0.113.9" \
         "22.1.1.1 80/tcp            ALLOW       198.51.100.5" \
         "Anywhere                   ALLOW       203.0.113.9" \
         ""; do
  STATUS="$s"
  UFW_CALLS=""
  ensure_ssh_rule
  chk "rule added for [${s:-empty status}]" "|allow OpenSSH" "$UFW_CALLS"
done

echo "25a. an IPv6-only rule does not authorize IPv4, whatever it looks like"
# The dangerous direction: `ufw --force enable` applies `default deny incoming`,
# and an operator reaches a Lightsail instance over its IPv4 address. Treating
# an IPv6-only rule as "SSH is handled" skips the IPv4 rule and then closes 22
# on the connection in use.
#
# All three render differently, which is the whole difficulty. Only the first
# carries the "(v6)" tag; the second is untagged and betrayed by its leading
# token; the third is untagged with an ordinary-looking first column and is
# recognisable only by the colons further along the line — and it is the most
# likely of the three, since narrowing SSH to your own address is why a host
# would have an IPv6-only rule at all.
for s in "22/tcp (v6)                ALLOW       Anywhere (v6)" \
         "2001:db8::1 22/tcp         ALLOW       2001:db8::9" \
         "22/tcp                     ALLOW       2001:db8::9" \
         "22/tcp                     LIMIT       2001:db8::9"; do
  STATUS="$s"
  UFW_CALLS=""
  ensure_ssh_rule
  chk "rule added for [${s:-empty status}]" "|allow OpenSSH" "$UFW_CALLS"
done

echo "26. a missing OpenSSH profile falls back to the port, it does not give up"
# `ufw allow OpenSSH` exits 1 where openssh-server is not installed, and the
# `ufw --force enable` that follows would then close 22 on a host reachable
# only over 22.
ufw() {
  if [ "$1" = status ]; then printf '%s\n' "$STATUS"; return 0; fi
  UFW_CALLS="$UFW_CALLS|$*"
  [ "$2" != OpenSSH ]   # stands in for "Could not find a profile matching"
}
STATUS="Status: inactive"; UFW_CALLS=""; LOGGED=""
ensure_ssh_rule
chk "port form used"  "|allow OpenSSH|allow 22/tcp" "$UFW_CALLS"
chk "reports success" 0 "$?"
# ufw's own "Could not find a profile" is suppressed, so the recovery has to
# say so itself or the log reads as if nothing happened.
case "$LOGGED" in
  *"allowing 22/tcp directly"*) echo "  ok   the fallback is on the record" ;;
  *) echo "  FAIL silent fallback: $LOGGED"; fail=1 ;;
esac

unset -f ufw log

# --- docs/deploy_to_lightsail.md, the SQLite cutover ------------------------
#
# This recipe hands the app role SUPERUSER, resets and reloads the production
# database, then takes the grant back. Every branch of it is a production
# incident if it runs when it should not, so it is exercised rather than read.

DOC="${2:-$ROOT/docs/deploy_to_lightsail.md}"

# extract_recipe <marker> — the fenced bash block containing <marker>, located
# by content, so a test follows its recipe if it moves within the page.
#
# The fence's own indentation is measured rather than assumed: recipes nested
# under a list item are indented two spaces and top-level ones are not, and a
# hard-coded indent silently matches no block at all — which reads as "the
# recipe moved" rather than as "this extractor cannot see it".
extract_recipe() {
  awk -v want="$1" '
    !inb && /^[[:space:]]*```bash$/ {
      inb = 1; buf = ""
      match($0, /^[[:space:]]*/); ind = substr($0, 1, RLENGTH)
      next
    }
    inb && $0 == ind "```" { if (buf ~ want) { printf "%s", buf; exit } inb = 0; next }
    inb { line = $0; sub("^" ind, "", line); buf = buf line "\n" }
  ' "$DOC"
}

recipe="$(extract_recipe 'copy_status=')"
case "$recipe" in
  *copy_status=*NOSUPERUSER*) : ;;
  *) echo "could not extract the cutover recipe from $DOC — has it moved?" >&2
     exit 1 ;;
esac

# Records what the recipe did against stubbed ssh/scp/kamal. FAIL_COPY and
# FAIL_REVOKE choose which step reports failure.
run_cutover() {
  local work; work="$(mktemp -d)"
  # Both placeholders have to go: `<` is a shell metacharacter even mid-word, so
  # a recipe still carrying `<deploy-user>@<instance-ip>` is a redirection, not a
  # destination, and bash would create files named after the placeholders.
  printf '%s' "$recipe" |
    sed -e 's/<instance-ip>/203.0.113.10/g' -e 's/<deploy-user>/collavre/g' \
        -e 's/<db-user>/collavre_user/g' \
    > "$work/recipe.sh"
  mkdir -p "$work/bin"
  cat > "$work/bin/ssh" <<'STUB'
#!/usr/bin/env bash
case "$*" in
  # The role is quoted in the recipe, so match it quoted: a pattern that still
  # said `ALTER ROLE collavre_user` would fall through to the catch-all and
  # every case here would pass without a grant ever being recognised.
  *'ALTER ROLE "collavre_user" SUPERUSER'*)   echo GRANT  >>"$TRACE"
                                            [ -z "$FAIL_GRANT" ] || exit 1 ;;
  *'ALTER ROLE "collavre_user" NOSUPERUSER'*) echo REVOKE >>"$TRACE"
                                            [ -z "$FAIL_REVOKE" ] || exit 255 ;;
  *"sudo rm"*)                              echo RM_STAGED >>"$TRACE" ;;
  *"sudo install"*)                         echo STAGE     >>"$TRACE"
                                            [ -z "$FAIL_STAGE" ] || exit 1 ;;
  # The receiving half of the blob copy. Reads the stream so the sending tar is
  # not killed by SIGPIPE, which would make FAIL_TAR indistinguishable from a
  # receiver that hung up.
  *"sudo tar -xf"*)                         cat >/dev/null
                                            echo BLOBS     >>"$TRACE"
                                            [ -z "$FAIL_BLOB" ] || exit 1 ;;
  *)                                        echo ssh       >>"$TRACE" ;;
esac
STUB
  printf '#!/usr/bin/env bash\necho scp >>"$TRACE"\n[ -z "$FAIL_SCP" ] || exit 1\n' \
    > "$work/bin/scp"
  # The snapshot is what the recipe sends, so the stub has to produce a file at
  # the path the VACUUM INTO names — otherwise the scp that follows would be
  # testing a missing file rather than the step under test.
  cat > "$work/bin/sqlite3" <<'STUB'
#!/usr/bin/env bash
echo SNAPSHOT >>"$TRACE"
[ -z "$FAIL_SNAP" ] || { echo "Error: near \"VACUUM\": syntax error" >&2; exit 1; }
sql="${*: -1}"
dest="${sql#*\'}"; dest="${dest%\'*}"
[ -z "$dest" ] || : > "$dest"
STUB
  # Sending half of the blob copy: its own status is the thing case 32h is about,
  # so it is a separate stub from the receiver rather than one knob for both.
  # It has to produce the archive at the path `-cf` names, because the transfer
  # that follows redirects from it — a stub that only reported its status would
  # leave the next line failing on a missing file instead of on FAIL_TAR.
  cat > "$work/bin/tar" <<'STUB'
#!/usr/bin/env bash
echo TAR_SEND >>"$TRACE"
[ -z "$FAIL_TAR" ] || exit 2
while [ "$#" -gt 0 ]; do
  case "$1" in
    -cf) : > "$2"; break ;;
  esac
  shift
done
STUB
  cat > "$work/bin/kamal.sh" <<'STUB'
#!/usr/bin/env bash
echo "kamal:$1${2:+ $2}" >>"$TRACE"
[ "${1:-}" != app ] || [ "${2:-}" != stop ] || [ -z "$FAIL_STOP" ] || exit 1
[ "${1:-}" != app ] || [ "${2:-}" != exec ] || [ -z "$FAIL_COPY" ] || exit 1
STUB
  chmod +x "$work/bin"/*
  cp "$work/bin/kamal.sh" "$work/kamal.sh"

  # NO_SQLITE3 is a host with no sqlite3 at all, and absence cannot be stubbed:
  # removing the stub would only uncover the real binary further down PATH. So
  # that case runs with PATH holding nothing but the stubs, which means the few
  # real commands the recipe needs have to be reachable there — and `bash`
  # itself is invoked by absolute path, since PATH is what would resolve it.
  local recipe_path="$work/bin:$PATH"
  if [ -n "${NO_SQLITE3:-}" ]; then
    rm -f "$work/bin/sqlite3"
    local c
    # env and bash among them: every stub here is `#!/usr/bin/env bash`, so
    # without them the stubs fail to start and the case passes on the wrong
    # failure — it did, before this line: `app stop` reported STOP FAILED and
    # the recipe never reached the snapshot at all.
    for c in mktemp rm env bash; do ln -s "$(command -v "$c")" "$work/bin/$c"; done
    recipe_path="$work/bin"
  fi

  TRACE="$work/trace"; : > "$TRACE"
  export TRACE FAIL_COPY="${FAIL_COPY:-}" FAIL_REVOKE="${FAIL_REVOKE:-}"
  export FAIL_SCP="${FAIL_SCP:-}" FAIL_STAGE="${FAIL_STAGE:-}"
  export FAIL_STOP="${FAIL_STOP:-}" FAIL_SNAP="${FAIL_SNAP:-}"
  export FAIL_TAR="${FAIL_TAR:-}" FAIL_BLOB="${FAIL_BLOB:-}"
  export FAIL_GRANT="${FAIL_GRANT:-}"
  # The recipe refuses unless the operator states the source is stopped, so the
  # default here is the stated case and case 32b is the unstated one.
  export source_quiesced="${SOURCE_QUIESCED-1}"
  RECIPE_OUT="$(cd "$work" && PATH="$recipe_path" "$BASH" ./recipe.sh 2>&1)"
  RECIPE_TRACE="$(paste -sd'|' "$TRACE")"
  rm -rf "$work"
}

echo "27. a clean cutover cleans up and boots"
FAIL_COPY='' FAIL_REVOKE='' FAIL_SCP='' FAIL_STAGE='' FAIL_STOP='' run_cutover
chk "staged file removed" 1 "$(grep -c RM_STAGED <<<"${RECIPE_TRACE//|/$'\n'}")"
chk "app booted"          1 "$(grep -cx 'kamal:app boot' <<<"${RECIPE_TRACE//|/$'\n'}")"

echo "28. a failed copy does not boot, and keeps the file the retry needs"
# MIGRATION_RUN_RESET drops the schema before loading, so a copy that dies
# partway leaves the database empty or half-populated. Booting serves that.
# The `sudo rm` is the other half: it destroys the staged SQLite file, so a
# retry would need another full scp of production rather than a re-run.
FAIL_COPY=1 FAIL_REVOKE='' FAIL_SCP='' FAIL_STAGE='' FAIL_STOP='' run_cutover
chk "app NOT booted"          0 "$(grep -cx 'kamal:app boot' <<<"${RECIPE_TRACE//|/$'\n'}")"
chk "staged file kept"        0 "$(grep -c RM_STAGED <<<"${RECIPE_TRACE//|/$'\n'}")"
chk "grant still taken back"  1 "$(grep -cx REVOKE <<<"${RECIPE_TRACE//|/$'\n'}")"
case "$RECIPE_OUT" in
  *"COPY FAILED"*"left stopped"*) echo "  ok   operator told what state it is in" ;;
  *) echo "  FAIL silent or partial: $RECIPE_OUT"; fail=1 ;;
esac

echo "29. a failed revoke does not boot the credential-bearing container"
# collavre_user is the role in DATABASE_URL. Booting while it is still a
# superuser hands every app container that privilege.
FAIL_COPY='' FAIL_REVOKE=1 FAIL_SCP='' FAIL_STAGE='' FAIL_STOP='' run_cutover
chk "app NOT booted" 0 "$(grep -cx 'kamal:app boot' <<<"${RECIPE_TRACE//|/$'\n'}")"
case "$RECIPE_OUT" in
  *"REVOKE FAILED"*"left stopped"*) echo "  ok   the still-superuser role is reported" ;;
  *) echo "  FAIL silent: $RECIPE_OUT"; fail=1 ;;
esac

echo "30. both failing reports both, not just the first"
FAIL_COPY=1 FAIL_REVOKE=1 FAIL_SCP='' FAIL_STAGE='' FAIL_STOP='' run_cutover
chk "app NOT booted" 0 "$(grep -cx 'kamal:app boot' <<<"${RECIPE_TRACE//|/$'\n'}")"
case "$RECIPE_OUT" in
  *"REVOKE FAILED"*"COPY FAILED"*) echo "  ok   both reported" ;;
  *) echo "  FAIL one masked the other: $RECIPE_OUT"; fail=1 ;;
esac

echo "31. a failed scp never converts, so a stale snapshot cannot be restored"
# The task loads from the file in the VOLUME, not from the one scp just sent.
# Case 24 deliberately keeps the staged file so a retry need not re-copy — so
# on a retry the volume holds the previous attempt's snapshot. Ungated, a
# failed scp converts from THAT: production silently rolled back to older data,
# reported as success, and the evidence deleted afterwards.
FAIL_COPY='' FAIL_REVOKE='' FAIL_SCP=1 FAIL_STAGE='' FAIL_STOP='' run_cutover
chk "no conversion ran"   0 "$(grep -cx 'kamal:app exec' <<<"${RECIPE_TRACE//|/$'\n'}")"
chk "no superuser granted" 0 "$(grep -cx GRANT <<<"${RECIPE_TRACE//|/$'\n'}")"
chk "app NOT booted"      0 "$(grep -cx 'kamal:app boot' <<<"${RECIPE_TRACE//|/$'\n'}")"
chk "stale file NOT deleted" 0 "$(grep -c RM_STAGED <<<"${RECIPE_TRACE//|/$'\n'}")"
case "$RECIPE_OUT" in
  *"STAGING FAILED"*"stale"*) echo "  ok   the retry hazard is named, not just the failure" ;;
  *) echo "  FAIL silent or vague: $RECIPE_OUT"; fail=1 ;;
esac

echo "32. a failed install into the volume is caught too, not just the scp"
# scp can succeed to /tmp and the privileged install still fail — no space,
# no docker group, volume gone.
FAIL_COPY='' FAIL_REVOKE='' FAIL_SCP='' FAIL_STAGE=1 FAIL_STOP='' run_cutover
chk "no conversion ran"    0 "$(grep -cx 'kamal:app exec' <<<"${RECIPE_TRACE//|/$'\n'}")"
chk "no superuser granted" 0 "$(grep -cx GRANT <<<"${RECIPE_TRACE//|/$'\n'}")"
chk "app NOT booted"       0 "$(grep -cx 'kamal:app boot' <<<"${RECIPE_TRACE//|/$'\n'}")"

echo "32a. a failed 'app stop' stages nothing, so no live container is converted under"
# The cutover's own MIGRATION_RUN_RESET does DROP SCHEMA public CASCADE. A stop
# that ran and failed leaves a container serving and polling while that lands,
# so the gate has to be on the stop's status, not on having written the line.
FAIL_COPY='' FAIL_REVOKE='' FAIL_SCP='' FAIL_STAGE='' FAIL_STOP=1 run_cutover
chk "nothing staged"       0 "$(grep -cx STAGE <<<"${RECIPE_TRACE//|/$'\n'}")"
chk "no superuser granted" 0 "$(grep -cx GRANT <<<"${RECIPE_TRACE//|/$'\n'}")"
chk "no conversion ran"    0 "$(grep -cx 'kamal:app exec' <<<"${RECIPE_TRACE//|/$'\n'}")"
chk "app NOT booted"       0 "$(grep -cx 'kamal:app boot' <<<"${RECIPE_TRACE//|/$'\n'}")"
case "$RECIPE_OUT" in
  *"STOP FAILED"*) echo "  ok   operator told the container may still be serving" ;;
  *) echo "  FAIL silent or vague: ${RECIPE_OUT:-(no output)}"; fail=1 ;;
esac

echo "32b. an undeclared source stops the whole recipe, before kamal is touched"
# The source is the one thing on this page that cannot be checked: SQLite has no
# pg_stat_activity, and the file looks identical whether the writer left or is
# between requests. So the recipe asks, and the ask has to be a gate rather than
# a sentence — nothing may run ahead of it, including `setup`, which on a
# half-configured instance is not a no-op.
SOURCE_QUIESCED='' FAIL_COPY='' FAIL_REVOKE='' FAIL_SCP='' FAIL_STAGE='' \
  FAIL_STOP='' run_cutover
chk "nothing ran at all"   "" "$RECIPE_TRACE"
chk "no snapshot taken"     0 "$(grep -cx SNAPSHOT <<<"${RECIPE_TRACE//|/$'\n'}")"
chk "app NOT booted"        0 "$(grep -cx 'kamal:app boot' <<<"${RECIPE_TRACE//|/$'\n'}")"
case "$RECIPE_OUT" in
  *REFUSING*source_quiesced=1*) echo "  ok   refusal names the way through" ;;
  *) echo "  FAIL vague or absent: ${RECIPE_OUT:-(no output)}"; fail=1 ;;
esac
unset SOURCE_QUIESCED

echo "32c. the source is snapshotted, not copied — WAL contents are not in the file"
# config/database.yml runs SQLite in WAL mode. A cp of production-primary.sqlite3
# omits everything committed since the last checkpoint, converts cleanly, and
# reports success — measured at 1 row of 3 with a writer still attached. The
# assertion is on both halves: a snapshot is taken, and the raw file is not what
# goes over the wire, since adding the snapshot while still sending the original
# would test nothing.
FAIL_COPY='' FAIL_REVOKE='' FAIL_SCP='' FAIL_STAGE='' FAIL_STOP='' run_cutover
chk "snapshot taken"                1 "$(grep -cx SNAPSHOT <<<"${RECIPE_TRACE//|/$'\n'}")"
chk "snapshot precedes the transfer" 1 \
  "$(grep -q 'SNAPSHOT|scp' <<<"$RECIPE_TRACE" && echo 1 || echo 0)"
chk "sqlite3 is what reads the source" 1 \
  "$(grep -c 'sqlite3 storage/production-primary.sqlite3' <<<"$recipe")"
chk "the raw database file is not sent" 0 \
  "$(grep -c 'scp storage/production-primary.sqlite3' <<<"$recipe")"

echo "32d. a failed snapshot converts nothing"
FAIL_SNAP=1 FAIL_COPY='' FAIL_REVOKE='' FAIL_SCP='' FAIL_STAGE='' FAIL_STOP='' \
  run_cutover
chk "nothing transferred"  0 "$(grep -cx scp <<<"${RECIPE_TRACE//|/$'\n'}")"
chk "nothing staged"       0 "$(grep -cx STAGE <<<"${RECIPE_TRACE//|/$'\n'}")"
chk "no superuser granted" 0 "$(grep -cx GRANT <<<"${RECIPE_TRACE//|/$'\n'}")"
chk "no conversion ran"    0 "$(grep -cx 'kamal:app exec' <<<"${RECIPE_TRACE//|/$'\n'}")"
chk "app NOT booted"       0 "$(grep -cx 'kamal:app boot' <<<"${RECIPE_TRACE//|/$'\n'}")"
case "$RECIPE_OUT" in
  *"SNAPSHOT FAILED"*"source is untouched"*)
    echo "  ok   says the source was only read" ;;
  *) echo "  FAIL silent or vague: ${RECIPE_OUT:-(no output)}"; fail=1 ;;
esac
unset FAIL_SNAP

echo "32e. a host without sqlite3 refuses rather than falling back to cp"
# The fallback is the bug. Absence is modelled by running with nothing but the
# stubs on PATH, because removing the stub alone would find the real binary.
NO_SQLITE3=1 FAIL_COPY='' FAIL_REVOKE='' FAIL_SCP='' FAIL_STAGE='' FAIL_STOP='' \
  run_cutover
chk "nothing transferred"  0 "$(grep -cx scp <<<"${RECIPE_TRACE//|/$'\n'}")"
chk "no conversion ran"    0 "$(grep -cx 'kamal:app exec' <<<"${RECIPE_TRACE//|/$'\n'}")"
chk "app NOT booted"       0 "$(grep -cx 'kamal:app boot' <<<"${RECIPE_TRACE//|/$'\n'}")"
case "$RECIPE_OUT" in
  *"no sqlite3"*) echo "  ok   names what is missing" ;;
  *) echo "  FAIL does not say why: ${RECIPE_OUT:-(no output)}"; fail=1 ;;
esac
unset NO_SQLITE3

echo "32f. Active Storage blobs are copied, before the conversion and the boot"
# The conversion copies active_storage_blobs rows; with :local storage the files
# they name sit beside the SQLite file on the source, and the volume here is new.
# Skipped, every attachment 404s from metadata that says it exists.
FAIL_COPY='' FAIL_REVOKE='' FAIL_SCP='' FAIL_STAGE='' FAIL_STOP='' run_cutover
chk "blobs sent"     1 "$(grep -cx TAR_SEND <<<"${RECIPE_TRACE//|/$'\n'}")"
chk "blobs unpacked" 1 "$(grep -cx BLOBS <<<"${RECIPE_TRACE//|/$'\n'}")"
chk "staged, then blobs, then granted" 1 \
  "$(grep -q 'STAGE|TAR_SEND|BLOBS|GRANT' <<<"$RECIPE_TRACE" && echo 1 || echo 0)"
chk "the SQLite files are excluded from that copy" 1 \
  "$(grep -c "exclude='\*.sqlite3\*'" <<<"$recipe")"

echo "32g. a failed blob copy converts nothing"
# Worth stopping for rather than warning about: the database would be correct and
# the app would boot, so the only symptom is broken attachments — found later, by
# a user, with the source already stopped.
FAIL_BLOB=1 FAIL_COPY='' FAIL_REVOKE='' FAIL_SCP='' FAIL_STAGE='' FAIL_STOP='' \
  run_cutover
chk "no superuser granted" 0 "$(grep -cx GRANT <<<"${RECIPE_TRACE//|/$'\n'}")"
chk "no conversion ran"    0 "$(grep -cx 'kamal:app exec' <<<"${RECIPE_TRACE//|/$'\n'}")"
chk "app NOT booted"       0 "$(grep -cx 'kamal:app boot' <<<"${RECIPE_TRACE//|/$'\n'}")"
case "$RECIPE_OUT" in
  *"BLOB COPY FAILED"*"attachments"*)
    echo "  ok   says what booting now would produce" ;;
  *) echo "  FAIL silent or vague: ${RECIPE_OUT:-(no output)}"; fail=1 ;;
esac
unset FAIL_BLOB

echo "32h. a sending tar that fails is caught, and never reaches the receiver"
# Why this is not `tar | ssh` with \$?: the status of a pipeline is its last
# element's, a receiver handed an empty stream unpacks it and exits 0, so a blob
# copy that copied nothing would report success — on the one path where the
# source is already stopped and the evidence is behind you. Staging the archive
# first makes the sender a gate rather than something to inspect afterwards.
FAIL_TAR=1 FAIL_BLOB='' FAIL_COPY='' FAIL_REVOKE='' FAIL_SCP='' FAIL_STAGE='' \
  FAIL_STOP='' run_cutover
chk "the transfer never ran" 0 "$(grep -cx BLOBS <<<"${RECIPE_TRACE//|/$'\n'}")"
chk "no conversion ran"      0 "$(grep -cx 'kamal:app exec' <<<"${RECIPE_TRACE//|/$'\n'}")"
chk "app NOT booted"         0 "$(grep -cx 'kamal:app boot' <<<"${RECIPE_TRACE//|/$'\n'}")"
case "$RECIPE_OUT" in
  *"BLOB COPY FAILED"*) echo "  ok   the sending half is not trusted to ssh" ;;
  *) echo "  FAIL the empty stream passed for a copy: ${RECIPE_OUT:-(no output)}"
     fail=1 ;;
esac
unset FAIL_TAR

echo "32i. the blob copy's status is readable in the shell the operator has"
# This harness runs the recipe under "$BASH" — a shell the page never names. It
# says five times over that these blocks get pasted into an interactive shell,
# and the operator's is whatever it is; on macOS that is zsh. So a bash-only
# construct here is not a style question: `${PIPESTATUS[0]}` is unset in zsh
# (spelled `$pipestatus` there, and 1-indexed), the arithmetic around it fails,
# and the pre-set 1 survives to report a copy that succeeded as failed —
# fail-closed, but a dead end that cannot be cleared, naming the one step that
# worked. Asserted against the text as well as by running it, because the run
# below is skipped where zsh is absent.
#
# Against the previous revision the discriminating assertions are "it converts"
# and "it boots" (`expected [1] got [0]`), not the message one: non-interactively
# zsh aborts the recipe at the failed arithmetic rather than continuing to print
# BLOB COPY FAILED, so that check passes there for the wrong reason. The dead-end
# message is what an interactive paste produces; what is asserted here is the
# thing both forms of the failure share — the cutover does not complete.
# Code lines only: the comment above the fix names PIPESTATUS to say why it is
# not used, and an assertion that forbade the word outright would forbid the
# explanation along with the construct.
chk "no PIPESTATUS in the cutover recipe" 0 \
  "$(grep -v '^[[:space:]]*#' <<<"$recipe" | grep -c PIPESTATUS)"
if command -v zsh >/dev/null; then
  BASH_SAVED="$BASH"; BASH="$(command -v zsh)"
  FAIL_TAR='' FAIL_BLOB='' FAIL_COPY='' FAIL_REVOKE='' FAIL_SCP='' FAIL_STAGE='' \
    FAIL_STOP='' run_cutover
  chk "under zsh: blobs unpacked" 1 "$(grep -cx BLOBS <<<"${RECIPE_TRACE//|/$'\n'}")"
  chk "under zsh: it converts"    1 \
    "$(grep -cx 'kamal:app exec' <<<"${RECIPE_TRACE//|/$'\n'}")"
  chk "under zsh: it boots"       1 \
    "$(grep -cx 'kamal:app boot' <<<"${RECIPE_TRACE//|/$'\n'}")"
  case "$RECIPE_OUT" in
    *"BLOB COPY FAILED"*)
      echo "  FAIL zsh reported the successful copy as failed: $RECIPE_OUT"; fail=1 ;;
    *) echo "  ok   no spurious failure under zsh" ;;
  esac
  # A control for the assertions above, so they cannot pass for the wrong
  # reason — that this zsh is one where PIPESTATUS happens to work. The
  # mechanism is measured rather than the outcome: reproducing the outcome needs
  # an interactive zsh, because non-interactively the failed arithmetic aborts
  # the script instead of leaving the stale 1 behind.
  chk "this zsh has no PIPESTATUS to read" UNSET \
    "$(zsh -c 'true | true; print -r -- "${PIPESTATUS[0]-UNSET}"' 2>/dev/null)"
  chk "and bash does"                      0 \
    "$("$BASH_SAVED" -c 'true | true; printf %s "${PIPESTATUS[0]-UNSET}"')"
  BASH="$BASH_SAVED"
else
  echo "  SKIP no zsh on this machine — the text assertion above is all that ran"
fi

echo "32j. the role in the grant is quoted, and a failed grant converts nothing"
# Same assumption as the database name further down the page, one setting over:
# DB_USER goes through `format('%I')` in the launch script, so `collavre-app` is
# a role it creates and `ALTER ROLE collavre-app SUPERUSER` is a syntax error.
# Unquoted, the whole cutover then fails on a host the script provisioned
# happily — and it fails while telling the operator the wrong thing, which is
# what the second half of this case is about.
chk "the grant quotes the role"  1 \
  "$(grep -c 'ALTER ROLE \\"<db-user>\\" SUPERUSER' <<<"$recipe")"
chk "so does the revoke"         1 \
  "$(grep -c 'ALTER ROLE \\"<db-user>\\" NOSUPERUSER' <<<"$recipe")"
FAIL_GRANT=1 FAIL_TAR='' FAIL_BLOB='' FAIL_COPY='' FAIL_REVOKE='' FAIL_SCP='' \
  FAIL_STAGE='' FAIL_STOP='' run_cutover
chk "no conversion ran" 0 "$(grep -cx 'kamal:app exec' <<<"${RECIPE_TRACE//|/$'\n'}")"
chk "app NOT booted"    0 "$(grep -cx 'kamal:app boot' <<<"${RECIPE_TRACE//|/$'\n'}")"
# Attempted anyway: a connection that dropped after the ALTER committed leaves
# the role raised with nothing on this side to say so, and NOSUPERUSER against a
# role that is not one succeeds and changes nothing.
chk "the revoke is still attempted" 1 "$(grep -cx REVOKE <<<"${RECIPE_TRACE//|/$'\n'}")"
case "$RECIPE_OUT" in
  *"GRANT FAILED"*"as it was"*) echo "  ok   says the database was not touched" ;;
  *) echo "  FAIL silent about the grant: ${RECIPE_OUT:-(no output)}"; fail=1 ;;
esac
# MIGRATION_RUN_RESET drops the schema first, so "empty or half-loaded" would be
# a false claim about a database no conversion ever reached.
case "$RECIPE_OUT" in
  *"COPY FAILED"*)
    echo "  FAIL blames a conversion that never ran: $RECIPE_OUT"; fail=1 ;;
  *) echo "  ok   does not blame a conversion that never ran" ;;
esac
FAIL_GRANT=1 FAIL_REVOKE=1 FAIL_COPY='' FAIL_SCP='' FAIL_STAGE='' FAIL_STOP='' \
  run_cutover
case "$RECIPE_OUT" in
  *"is still a superuser"*)
    echo "  FAIL claims a grant that never happened: $RECIPE_OUT"; fail=1 ;;
  *"read"*rolsuper*) echo "  ok   sends the operator to read rolsuper instead" ;;
  *) echo "  FAIL vague about which repair is needed: ${RECIPE_OUT:-(no output)}"
     fail=1 ;;
esac
unset FAIL_GRANT

echo "33. staging renames into place rather than writing the live path directly"
# An interrupted copy must leave the previous file intact, not a truncated
# database the next run would happily convert from.
case "$recipe" in
  *".incoming"*"mv"*) echo "  ok   staged under a temporary name, then renamed" ;;
  *) echo "  FAIL staging writes the live path directly"; fail=1 ;;
esac

# --- the fresh-install recipe ----------------------------------------------

fresh="$(extract_recipe 'load_status=')"
case "$fresh" in
  *db:schema:load:primary*load_status=*) : ;;
  *) echo "could not extract the fresh-install recipe from $DOC — has it moved?" >&2
     exit 1 ;;
esac

run_fresh() {
  local work; work="$(mktemp -d)"
  printf '%s' "$fresh" > "$work/recipe.sh"
  mkdir -p "$work/bin"
  cat > "$work/bin/kamal.sh" <<'STUB'
#!/usr/bin/env bash
echo "kamal:$1${2:+ $2}" >>"$TRACE"
[ "${1:-}" != app ] || [ "${2:-}" != stop ] || [ -z "$FAIL_STOP" ] || exit 1
[ "${1:-}" != app ] || [ "${2:-}" != exec ] || [ -z "$FAIL_LOAD" ] || exit 1
STUB
  chmod +x "$work/bin"/*
  cp "$work/bin/kamal.sh" "$work/kamal.sh"
  TRACE="$work/trace"; : > "$TRACE"
  export TRACE FAIL_LOAD="${FAIL_LOAD:-}" FAIL_STOP="${FAIL_STOP:-}"
  FRESH_OUT="$(cd "$work" && PATH="$work/bin:$PATH" bash ./recipe.sh 2>&1)"
  FRESH_TRACE="$(paste -sd'|' "$TRACE")"
  rm -rf "$work"
}

echo "34. a clean fresh install prints the admin password and boots"
FAIL_LOAD='' FAIL_STOP='' run_fresh
chk "app stopped first" 1 "$(grep -cx 'kamal:app stop' <<<"${FRESH_TRACE//|/$'\n'}")"
chk "app booted"        1 "$(grep -cx 'kamal:app boot' <<<"${FRESH_TRACE//|/$'\n'}")"

echo "35. a failed schema load does not boot the app onto a partial schema"
# db:schema:load drops and recreates every table, and db:seed is what creates
# the first admin — so a load that resets the database but does not finish
# leaves an app with no way to sign in and no owner on any record.
FAIL_LOAD=1 FAIL_STOP='' run_fresh
chk "app NOT booted" 0 "$(grep -cx 'kamal:app boot' <<<"${FRESH_TRACE//|/$'\n'}")"
case "$FRESH_OUT" in
  *"LOAD FAILED"*"left stopped"*) echo "  ok   operator told what state it is in" ;;
  *) echo "  FAIL silent or partial: $FRESH_OUT"; fail=1 ;;
esac

echo "35a. a failed 'app stop' loads nothing, rather than dropping tables under a live container"
# Adding the `app stop` only fixed the case where nobody ran it. Without
# `set -e` a stop that *ran and failed* — unreachable host, a docker daemon
# that will not answer — falls straight through to the load, which is the live
# schema replacement the stop exists to prevent.
FAIL_LOAD='' FAIL_STOP=1 run_fresh
chk "nothing loaded"  0 "$(grep -cx 'kamal:app exec' <<<"${FRESH_TRACE//|/$'\n'}")"
chk "app NOT booted"  0 "$(grep -cx 'kamal:app boot' <<<"${FRESH_TRACE//|/$'\n'}")"
case "$FRESH_OUT" in
  *"STOP FAILED"*) echo "  ok   operator told the container may still be serving" ;;
  *) echo "  FAIL silent or vague: ${FRESH_OUT:-(no output)}"; fail=1 ;;
esac

# --- install_authorized_keys ------------------------------------------------
#
# The failure this guards is not a lost key but an aborted run: `cat f >> f` is
# an error under GNU cat, and `set -e` would end provisioning at that line.

LOGGED=""
# shellcheck disable=SC2329  # called by install_authorized_keys, eval'd from the script
log() { LOGGED="$LOGGED $*"; }

echo "36. the deploy user's own keys are not copied onto themselves"
# APP_SSH_USER=ubuntu — src and dest are one file.
h=$(mktemp -d); mkdir -p "$h/ubuntu/.ssh"
printf 'ssh-ed25519 CLOUDKEY cloud\n' > "$h/ubuntu/.ssh/authorized_keys"
SSH_PUBLIC_KEY="" LOGGED=""
install_authorized_keys "$h/ubuntu/.ssh/authorized_keys" "$h"
chk "run survives"        0 "$?"
chk "the key is intact"   1 "$(grep -c CLOUDKEY "$h/ubuntu/.ssh/authorized_keys")"
case "$LOGGED" in
  *"already in place"*) echo "  ok   says why it copied nothing" ;;
  *) echo "  FAIL no explanation: $LOGGED"; fail=1 ;;
esac

echo "37. a separate deploy user still inherits the cloud user's keys"
mkdir -p "$h/collavre/.ssh"; : > "$h/collavre/.ssh/authorized_keys"
SSH_PUBLIC_KEY="" LOGGED=""
install_authorized_keys "$h/collavre/.ssh/authorized_keys" "$h"
chk "cloud key copied" 1 "$(grep -c CLOUDKEY "$h/collavre/.ssh/authorized_keys")"

echo "38. an explicit SSH_PUBLIC_KEY is added once, not once per run"
# shellcheck disable=SC2034  # read by install_authorized_keys, eval'd from the script
SSH_PUBLIC_KEY="ssh-ed25519 EXPLICIT me"
install_authorized_keys "$h/collavre/.ssh/authorized_keys" "$h"
install_authorized_keys "$h/collavre/.ssh/authorized_keys" "$h"
chk "no duplicate" 1 "$(grep -c EXPLICIT "$h/collavre/.ssh/authorized_keys")"

# --- revoke_prior_ssh_key ---------------------------------------------------
#
# The same family as the deploy-user and DB_USER rotations: appending the new
# key converges the successor and leaves the predecessor authorized. This
# account is in `docker` with passwordless sudo, so the key an operator thinks
# they retired still reaches root.

AK="$h/collavre/.ssh/authorized_keys"
OLD="ssh-ed25519 OLDKEY retired"
NEW="ssh-ed25519 NEWKEY current"
OPERATOR="ssh-rsa OPKEY someone-else"
st=$(mktemp -d)

echo "39. rotating SSH_PUBLIC_KEY withdraws the key the last run installed"
printf '%s\n%s\n' "$OLD" "$OPERATOR" > "$AK"
printf '%s\n' "$OLD" > "$st/ssh_public_key"
SSH_PUBLIC_KEY="$NEW" LOGGED=""
install_authorized_keys "$AK" "$h"
revoke_prior_ssh_key "$AK" "$st/ssh_public_key"
chk "the new key is authorized"    1 "$(grep -cxF "$NEW" "$AK")"
chk "the retired key is gone"      0 "$(grep -cxF "$OLD" "$AK")"
chk "an operator's own key stays"  1 "$(grep -cxF "$OPERATOR" "$AK")"
chk "state advanced to the new key" "$NEW" "$(cat "$st/ssh_public_key")"

echo "40. an unchanged SSH_PUBLIC_KEY withdraws nothing"
before="$(cat "$AK")"
revoke_prior_ssh_key "$AK" "$st/ssh_public_key"
chk "authorized_keys untouched" "$before" "$(cat "$AK")"

echo "41. an empty SSH_PUBLIC_KEY means 'keep the cloud keys', not 'retire mine'"
# Dropping the variable from a re-run must not strand the operator.
SSH_PUBLIC_KEY=""
revoke_prior_ssh_key "$AK" "$st/ssh_public_key"
chk "nothing withdrawn" "$before" "$(cat "$AK")"

echo "42. the predecessor is never withdrawn before the successor is in place"
# An interrupted run must leave two usable keys, never zero.
printf '%s\n' "$OLD" > "$AK"
printf '%s\n' "$OLD" > "$st/ssh_public_key"
SSH_PUBLIC_KEY="$NEW"
revoke_prior_ssh_key "$AK" "$st/ssh_public_key"     # successor not added yet
chk "the old key still lets you in" 1 "$(grep -cxF "$OLD" "$AK")"

echo "43. first run and an already-absent key are no-ops"
st2=$(mktemp -d)
printf '%s\n' "$NEW" > "$AK"
# shellcheck disable=SC2034  # read by revoke_prior_ssh_key, eval'd from the script
SSH_PUBLIC_KEY="$NEW"
revoke_prior_ssh_key "$AK" "$st2/ssh_public_key"    # no marker yet
chk "key kept"          1 "$(grep -cxF "$NEW" "$AK")"
chk "marker recorded"   "$NEW" "$(cat "$st2/ssh_public_key")"
printf '%s\n' "$OLD" > "$st2/ssh_public_key"        # recorded but already removed
revoke_prior_ssh_key "$AK" "$st2/ssh_public_key"
chk "still just the new key" "$NEW" "$(cat "$AK")"

echo "44. a rewrite that cannot be completed keeps the old key instead of none"
# The realistic trigger is a full disk: `grep -vxF > $tmp` writes nothing and
# exits 2, the `|| true` hides it, and writing that empty result back would
# leave authorized_keys with no keys at all — locking the deploy account out of
# a host whose only other way in is the account being rotated. Shadowing grep
# reproduces exactly that: the filter fails, the membership tests do not.
st3=$(mktemp -d)
printf '%s\n%s\n' "$NEW" "$OLD" > "$AK"
printf '%s\n' "$OLD" > "$st3/ssh_public_key"
# shellcheck disable=SC2034  # read by revoke_prior_ssh_key, eval'd from the script
SSH_PUBLIC_KEY="$NEW"
LOGGED=""
# shellcheck disable=SC2329  # shadows grep for revoke_prior_ssh_key only
grep() { case "$*" in *-vxF*) return 2 ;; *) command grep "$@" ;; esac; }
revoke_prior_ssh_key "$AK" "$st3/ssh_public_key"
unset -f grep
chk "the account keeps a way in"      1 "$(command grep -cxF "$NEW" "$AK")"
chk "the un-withdrawn key is kept"    1 "$(command grep -cxF "$OLD" "$AK")"
# The retry record is the queue, not the marker. The marker names the key the
# host is deployed with and advances; a key whose withdrawal failed stays
# queued, which is what makes a later run try again. Asserted on the queue
# rather than on the marker because the previous form could only express one of
# the two, and expressed the wrong one — see 44a.
chk "the un-withdrawn key stays queued" 1 \
  "$(command grep -cxF "$OLD" "$st3/ssh_public_keys" 2>/dev/null || echo 0)"
chk "and the marker names the deployed key" "$NEW" "$(cat "$st3/ssh_public_key")"

case "$LOGGED" in
  *WARNING*"still authorized"*) echo "  ok   the failure is reported, not claimed as a success" ;;
  *) echo "  FAIL silent or reported as withdrawn: $LOGGED"; fail=1 ;;
esac

echo "44a. and the NEXT run actually retries the withdrawal it could not do"
# The point of keeping the record: without this, 44 asserts only that a file
# has a line in it. Same state dir, same authorized_keys, no shadowed grep.
LOGGED=""
revoke_prior_ssh_key "$AK" "$st3/ssh_public_key"
chk "the old key is withdrawn on the retry" 0 "$(command grep -cxF "$OLD" "$AK")"
chk "the account still has its key"         1 "$(command grep -cxF "$NEW" "$AK")"
chk "and the queue is down to the current key" "$NEW" "$(cat "$st3/ssh_public_keys")"

echo "45. a rewrite that stops PART WAY also keeps the old key instead of none"
# Case 40 is the write that produces nothing. This is the write that produces
# some of the file, which a size test cannot tell from a good one — and it is
# the likelier shape on a nearly-full disk. It matters more than it looks:
# install_authorized_keys *appends*, so the successor is the last line and is
# exactly what a short write drops. The result is a non-empty authorized_keys
# that no longer contains the key the operator is rotating to.
st4=$(mktemp -d)
printf '%s\n%s\n%s\n' "$OLD" "$OPERATOR" "$NEW" > "$AK"
printf '%s\n' "$OLD" > "$st4/ssh_public_key"
# shellcheck disable=SC2034  # read by revoke_prior_ssh_key, eval'd from the script
SSH_PUBLIC_KEY="$NEW"
LOGGED=""
# Emits a truncated result — the operator key but not the trailing successor —
# then fails, exactly as grep does when it runs out of space mid-write.
# shellcheck disable=SC2329  # shadows grep for revoke_prior_ssh_key only
grep() {
  case "$*" in
    *-vxF*) printf '%s\n' "$OPERATOR"; return 2 ;;
    *) command grep "$@" ;;
  esac
}
revoke_prior_ssh_key "$AK" "$st4/ssh_public_key"
unset -f grep
chk "the account keeps a way in"     1 "$(command grep -cxF "$NEW" "$AK")"
chk "the un-withdrawn key is kept"   1 "$(command grep -cxF "$OLD" "$AK")"
chk "the operator's key is kept"     1 "$(command grep -cxF "$OPERATOR" "$AK")"
chk "the un-withdrawn key stays queued" 1 \
  "$(command grep -cxF "$OLD" "$st4/ssh_public_keys" 2>/dev/null || echo 0)"
chk "and the marker names the deployed key" "$NEW" "$(cat "$st4/ssh_public_key")"
case "$LOGGED" in
  *WARNING*"still authorized"*) echo "  ok   the partial write is reported, not claimed as a success" ;;
  *) echo "  FAIL silent or reported as withdrawn: $LOGGED"; fail=1 ;;
esac

echo "46. the scratch file is staged beside authorized_keys, not in TMPDIR"
# Same filesystem, so the rewrite cannot fail for space the staging just
# proved is available, and a full or unwritable /tmp is not on its own able to
# break the file the operator logs in with.
#
# Asserted on the path mktemp is *asked* for rather than by pointing TMPDIR
# somewhere broken: GNU mktemp fails on a missing TMPDIR but BSD mktemp falls
# back to a private directory and succeeds, so the TMPDIR form would pass
# vacuously on the machine this harness usually runs on and only mean
# something on the host being provisioned.
st5=$(mktemp -d)
printf '%s\n%s\n' "$OLD" "$NEW" > "$AK"
printf '%s\n' "$OLD" > "$st5/ssh_public_key"
# shellcheck disable=SC2034  # read by revoke_prior_ssh_key, eval'd from the script
SSH_PUBLIC_KEY="$NEW"
LOGGED=""
# Recorded to a file, not a variable: the call site is `tmp="$(mktemp ...)"`,
# a command substitution, so anything the shadow assigns dies with its
# subshell.
TEMPLATE_LOG="$st5/mktemp_template"
: > "$TEMPLATE_LOG"
# shellcheck disable=SC2329  # shadows mktemp for revoke_prior_ssh_key only
mktemp() { printf '%s\n' "${1:-(no template)}" >> "$TEMPLATE_LOG"; command mktemp "$@"; }
revoke_prior_ssh_key "$AK" "$st5/ssh_public_key"
unset -f mktemp
# The authorized_keys rewrite specifically, not merely the first mktemp of the
# call: this function also writes state files under $STATE_DIR through
# write_state_file, which legitimately stages beside *those*. Matching on the
# .revoke. template is what keeps the assertion about the file the operator
# logs in with — and it still fails on an implementation that stages in TMPDIR,
# since there would then be no such line at all.
revoke_template="$(command grep -F '.revoke.' "$TEMPLATE_LOG" | head -1)"
chk "the authorized_keys rewrite was staged at all" \
  1 "$([ -n "$revoke_template" ] && echo 1 || echo 0)"
chk "staged in the target's own directory" \
  "$(dirname "$AK")" "$(dirname "$revoke_template")"
chk "the rotation still completed"  0 "$(command grep -cxF "$OLD" "$AK")"
chk "the new key is authorized"     1 "$(command grep -cxF "$NEW" "$AK")"
chk "no scratch file left behind"   0 "$(find "$(dirname "$AK")" -name '*.revoke.*' | wc -l | tr -d ' ')"

unset -f log

# --- reassign_prior_db_role -------------------------------------------------
#
# A rotation that reports success while the new role cannot read its own tables
# and the old credential still works is worse than one that refuses.

SQL=""
LOGGED=""
ROLE_EXISTS=1
ROLE_IS_SUPER=f
# How many application objects the predecessor still owns. 1 is the untransferred
# state, which is what every case written before the by-hand transfer existed
# assumes.
OWNS=1
# shellcheck disable=SC2034  # read by reassign_prior_db_role, eval'd from the script
DB_NAME=collavre_production
# A statement whose text contains $FAIL_SQL fails the way psql does under
# ON_ERROR_STOP: non-zero, nothing on stdout. Injected rather than provoked,
# because the defect is what the caller does with the status — a REASSIGN that
# really fails needs a permission or lock condition this harness has no database
# to create, and the shape of the failure is the same either way.
FAIL_SQL=""
# shellcheck disable=SC2329  # called by reassign_prior_db_role
psql_as_postgres() {
  if [ -n "$FAIL_SQL" ]; then
    case "$2" in *"$FAIL_SQL"*) return 1 ;; esac
  fi
  case "$2" in
    # Must precede the count(*) branch: the ownership query is a count too, and
    # matching it as the role-existence probe would make every case below read
    # a rotation as already transferred.
    *pg_get_userbyid*) printf '%s\n' "$OWNS"; return 0 ;;
    *"count(*)"*) printf '%s\n' "$ROLE_EXISTS"; return 0 ;;
    *rolsuper*)   printf '%s\n' "$ROLE_IS_SUPER"; return 0 ;;
  esac
  SQL="$SQL|$2"
}
# shellcheck disable=SC2329  # called by reassign_prior_db_role
log() { LOGGED="$LOGGED $*"; }
# Clears the queue, so each case starts from a host whose entire recorded state
# is the marker it just wrote. Before the queue existed, `db_user` was the only
# input and every case could share one state dir; now a rotation leaves a
# db_users file behind, and a later case that rewrites only the marker would
# otherwise inherit the previous case's predecessor. Use rotate_resume for the
# cases that mean to carry that state over.
rotate() { SQL=""; LOGGED=""; rm -f "${2%/*}/db_users"; reassign_prior_db_role "$@"; }
rotate_resume() { SQL=""; LOGGED=""; reassign_prior_db_role "$@"; }

echo "47. rotating DB_USER moves the tables and retires the old credential"
# ALTER DATABASE ... OWNER only moves the database. Every table and sequence
# the app created stays with the old role, so the new one in DATABASE_URL gets
# "permission denied" on its own data — while the old role keeps LOGIN and the
# same password out of the state file.
d3=$(mktemp -d); printf 'collavre_user\n' > "$d3/db_user"
ROLE_EXISTS=1 ROLE_IS_SUPER=f
rotate collavre_app "$d3/db_user"
chk "ownership moved, then login revoked" \
    '|REASSIGN OWNED BY "collavre_user" TO "collavre_app"|ALTER ROLE "collavre_user" NOLOGIN' \
    "$SQL"

echo "48. an unchanged DB_USER touches nothing"
# Its own state dir, rather than continuing from 47. 47 leaves a host mid-
# rotation: it moved the objects to collavre_app and — as the real script does
# on the next line, and this harness does not — had yet to advance the marker.
# Re-running there with collavre_user is not "unchanged DB_USER", it is the
# interrupted A -> B -> C sequence, and reassigning is the correct answer to it
# (see 48a). Sharing $d3 only looked harmless while the single marker was
# forgetting the predecessor that makes the two cases different.
d3b=$(mktemp -d); printf 'collavre_user\n' > "$d3b/db_user"
rotate collavre_user "$d3b/db_user"
chk "no SQL" "" "$SQL$LOGGED"

echo "48a. a rotation interrupted before the marker advanced is still completed"
# Continuing from 47 deliberately: objects with collavre_app, marker still at
# collavre_user, which is where a run killed between the reassign and the
# marker write leaves the host. Asking for a third role must move the objects
# from the one that actually holds them.
#
# Against the previous revision this reassigns from collavre_user — the marker
# — which owns nothing, so nothing moves, and the summary hands out a
# DATABASE_URL for a role that cannot read a table.
rotate_resume collavre_third "$d3/db_user"
chk "moved from the role that actually owns them" \
    '|REASSIGN OWNED BY "collavre_app" TO "collavre_third"|ALTER ROLE "collavre_app" NOLOGIN' \
    "$SQL"
chk "and the queue is down to the current role" "collavre_third" "$(cat "$d3/db_users")"

echo "48b. a statement that fails leaves the role queued, not retired"
# reassign_one_db_role is called as `... || kept="$kept$prior"`, and a function
# invoked on the left of `||` runs with errexit suppressed for its whole body.
# So `set -e` did not stop it at a failed REASSIGN: it fell through to
# ALTER ROLE ... NOLOGIN and returned the status of the last log, which is zero.
# Measured on the previous revision with the REASSIGN made to fail:
#
#   rc=0   objects still owned by A   NOLOGIN applied to A   queue [B]
#
# — the predecessor owns every table, can no longer log in, and has just been
# dropped from the only record that named it. Asserted on three failure points
# rather than one: the two statements, and the probe whose empty output reads as
# "no such role" and retires the entry just as quietly.
d3c=$(mktemp -d); printf 'collavre_user\n' > "$d3c/db_user"
ROLE_EXISTS=1 ROLE_IS_SUPER=f
FAIL_SQL="REASSIGN OWNED"
rotate collavre_app "$d3c/db_user"
chk "the run stops rather than continuing to the summary" 1 "$?"
chk "LOGIN is not revoked from the role that still owns the tables" \
    "" "$(printf '%s' "$SQL" | grep -o 'NOLOGIN' || true)"
chk "and the predecessor stays queued" \
    "collavre_user collavre_app" "$(tr '\n' ' ' < "$d3c/db_users" | sed 's/ *$//')"
case "$LOGGED" in
  *"could not move ownership"*"stays queued"*) echo "  ok   says what did not happen" ;;
  *) echo "  FAIL claimed the move it did not make: $LOGGED"; fail=1 ;;
esac
# Ownership moved, LOGIN did not. Retrying is a no-op for the first statement
# and a retry of the second, so the entry has to survive this too.
FAIL_SQL="NOLOGIN"
rotate collavre_app "$d3c/db_user"
chk "a failed NOLOGIN also stops the run" 1 "$?"
chk "and keeps the role queued" \
    "collavre_user collavre_app" "$(tr '\n' ' ' < "$d3c/db_users" | sed 's/ *$//')"
# A probe that cannot be answered is not an answer: empty output compares equal
# to neither 1 nor t, which is "no such role" and "not a superuser" — both of
# which retire the entry.
FAIL_SQL="pg_roles WHERE rolname"
rotate collavre_app "$d3c/db_user"
chk "an unanswerable probe stops the run too" 1 "$?"
chk "and keeps the role queued" \
    "collavre_user collavre_app" "$(tr '\n' ' ' < "$d3c/db_users" | sed 's/ *$//')"
chk "with no SQL attempted" "" "$SQL"
FAIL_SQL=""
# The control in the other direction, and the one that matters most here: a
# guard that reports failure on a clean rotation would stop every run.
rotate collavre_app "$d3c/db_user"
chk "a rotation with nothing failing still reports success" 0 "$?"
chk "and the queue is down to the current role" "collavre_app" "$(cat "$d3c/db_users")"
rm -rf "$d3c"

echo "49. a superuser predecessor stops the run rather than half-rotating it"
# DB_USER=postgres on a first run is legal, and the rotation away from it cannot
# be completed: PostgreSQL refuses to reassign a superuser's objects at all. The
# earlier form warned and returned, by which point the caller's SQL had already
# moved the database — so the new role owned it and could not read one table,
# and the advanced marker meant no later run looked at the old role again.
printf 'postgres\n' > "$d3/db_user"
ROLE_IS_SUPER=t
# `rotate` runs in a subshell here, to capture the die() output, so the SQL=""
# it performs does not reach this shell — "$SQL" below is whatever the last
# non-subshell case left behind. That read as a pass only while the preceding
# case happened to run no SQL; 48a runs some. Same shape as the leak recorded
# at 86c, one variable over: state a case relies on being empty has to be made
# empty here rather than assumed.
SQL=""
rm -f "$d3/db_users"
out="$( (rotate collavre_app "$d3/db_user") 2>&1 )"
chk "exits non-zero" 1 "$?"
chk "no SQL ran"     "" "$SQL"
case "$out" in
  *"is a superuser"*"cannot be reassigned"*) echo "  ok   says why, not just that" ;;
  *) echo "  FAIL unhelpful: $out"; fail=1 ;;
esac

echo "50. the refusal happens before the database SQL, with the marker intact"
# The point of a separate pre-check: reassign_prior_db_role runs after ALTER
# DATABASE ... OWNER, so refusing there is already too late.
refuse() { SQL=""; LOGGED=""; refuse_superuser_db_rotation "$@"; }
printf 'postgres\n' > "$d3/db_user"
ROLE_EXISTS=1 ROLE_IS_SUPER=t
out="$( (refuse collavre_app "$d3/db_user") 2>&1 )"
chk "exits non-zero"          1 "$?"
chk "marker still names the old role" "postgres" "$(cat "$d3/db_user")"
case "$out" in
  *"provisioned with DB_USER='postgres'"*"Nothing has been changed"*"re-run"*)
    echo "  ok   names the state and the way out" ;;
  *) echo "  FAIL unhelpful: $out"; fail=1 ;;
esac
# The three shapes that must still be let through.
ROLE_IS_SUPER=f
refuse collavre_app "$d3/db_user"
chk "an ordinary predecessor proceeds" 0 "$?"
ROLE_IS_SUPER=t
refuse postgres "$d3/db_user"
chk "an unchanged superuser DB_USER proceeds" 0 "$?"
d3b=$(mktemp -d)
refuse collavre_app "$d3b/db_user"
chk "a first run proceeds" 0 "$?"
ROLE_EXISTS=0 ROLE_IS_SUPER=t
refuse collavre_app "$d3/db_user"
chk "a dropped predecessor proceeds" 0 "$?"
ROLE_EXISTS=1 ROLE_IS_SUPER=f

echo "50a. a superuser predecessor that owns nothing has already been transferred"
# The runbook's answer to case 50 is "move the objects by hand, then re-run",
# and that recipe deliberately leaves postgres a superuser — NOLOGIN on the
# bootstrap role is a lockout, not a revocation. So a guard that fires on
# rolsuper alone fires again on the very re-run it asked for, and the rotation
# can never be completed by any route the runbook describes.
printf 'postgres\n' > "$d3/db_user"
ROLE_EXISTS=1 ROLE_IS_SUPER=t OWNS=0
# Not in a subshell: the let-through path is asserted on what it logged, and
# $LOGGED would not survive one.
refuse collavre_app "$d3/db_user"
chk "the re-run is let through" 0 "$?"
case "$LOGGED" in
  *"owns nothing"*"keeps LOGIN"*)
    echo "  ok   says the old superuser credential is NOT retired" ;;
  *) echo "  FAIL silent or unclear: $LOGGED"; fail=1 ;;
esac
# Still refuses while anything is left, so the let-through is the transfer and
# not the superuser check going away.
OWNS=3
out="$( (refuse collavre_app "$d3/db_user") 2>&1 )"
chk "a partial transfer still refuses" 1 "$?"
case "$out" in
  *"3 object(s)"*) echo "  ok   says how many are left" ;;
  *) echo "  FAIL does not say what is outstanding: $out"; fail=1 ;;
esac
# An unanswerable question reads as the unsafe answer: a database that does not
# exist yet, or a query that failed, returns nothing and must not pass for zero.
OWNS=""
out="$( (refuse collavre_app "$d3/db_user") 2>&1 )"
chk "an unreadable count refuses" 1 "$?"
OWNS=1

echo "50b. the completed transfer neither reassigns nor touches the superuser login"
# Both statements must be skipped rather than left to no-op. REASSIGN OWNED BY
# postgres is rejected whether or not it owns anything ("required by the database
# system"), so it would end the run at the last step of a rotation that had
# otherwise succeeded — and ALTER ROLE postgres NOLOGIN is accepted by
# PostgreSQL, after which nothing can log in to undo it.
printf 'postgres\n' > "$d3/db_user"
ROLE_EXISTS=1 ROLE_IS_SUPER=t OWNS=0
rotate collavre_app "$d3/db_user"
chk "proceeds" 0 "$?"
chk "no SQL at all" "" "$SQL"
case "$LOGGED" in
  *"owns nothing"*) echo "  ok   says the role was left alone, and why" ;;
  *) echo "  FAIL silent: $LOGGED"; fail=1 ;;
esac
# The backstop still stands for a genuinely untransferred superuser.
OWNS=2
out="$( (rotate collavre_app "$d3/db_user") 2>&1 )"
chk "an untransferred superuser still dies" 1 "$?"
chk "and still runs no SQL" "" "$SQL"
ROLE_EXISTS=1 ROLE_IS_SUPER=f OWNS=1

echo "50c. a probe the cluster cannot answer stops the run rather than passing it"
# 50a already asserts this for the ownership count ("an unreadable count
# refuses"). The two role probes above it did not: they compared the *output*
# of psql and threw the status away, so a connection that died produced an
# empty string, which is neither "1" nor "t", and the guard read a dead cluster
# as "no such role" and then as "not a superuser".
#
# Proceeding here is not a refusal deferred to reassign_prior_db_role, which is
# what makes this worth a case of its own rather than a tidier spelling: the
# call site runs this guard *before* the SQL block, and that block contains
# ALTER DATABASE ... OWNER TO. A bypass therefore moves the stop from "nothing
# has been changed" to a host whose database belongs to the new role and whose
# every table still belongs to the superuser — the exact half-rotated state
# case 50 says the pre-check exists to make unreachable.
#
# The die message names the port, and DB_PORT is not set until the cluster
# cases below; set here rather than moved, since those cases share the value
# and reordering them to suit this one would be the tail wagging the dog.
DB_PORT=5432
printf 'postgres\n' > "$d3/db_user"
ROLE_EXISTS=1 ROLE_IS_SUPER=t OWNS=2
for q in 'count(*) FROM pg_roles' 'rolsuper'; do
  FAIL_SQL="$q"
  out="$( (refuse collavre_app "$d3/db_user") 2>&1 )"
  chk "an unanswerable '$q' stops the run" 1 "$?"
  case "$out" in
    *"could not ask the cluster"*"Nothing has been changed"*"re-run"*)
      echo "  ok   '$q': says what could not be asked, and that nothing changed" ;;
    *) echo "  FAIL '$q': unhelpful or silent: $out"; fail=1 ;;
  esac
done
FAIL_SQL=""
# The control in the other direction, and it is the one that matters: this
# guard runs on every re-run that changes DB_USER, so a probe treated as
# unanswerable when it did answer would refuse every rotation on the host.
# 50's four let-through shapes are asserted against a working psql above; this
# re-asserts the two that the change actually rewrote.
ROLE_IS_SUPER=f
refuse collavre_app "$d3/db_user"
chk "an answered 'not a superuser' still proceeds" 0 "$?"
ROLE_EXISTS=0 ROLE_IS_SUPER=t
refuse collavre_app "$d3/db_user"
chk "an answered 'no such role' still proceeds"    0 "$?"
ROLE_EXISTS=1 ROLE_IS_SUPER=f OWNS=1

echo "51. first run, emptied marker and a dropped role are all no-ops"
d4=$(mktemp -d)
ROLE_IS_SUPER=f
rotate collavre_user "$d4/db_user"          # no marker yet
chk "no marker"    "" "$SQL$LOGGED"
: > "$d4/db_user"
rotate collavre_user "$d4/db_user"          # marker exists but is empty
chk "empty marker" "" "$SQL$LOGGED"
printf 'collavre_user\n' > "$d4/db_user"
ROLE_EXISTS=0                                # dropped by hand
rotate collavre_app "$d4/db_user"
chk "role is gone" "" "$SQL$LOGGED"

unset -f psql_as_postgres log rotate

# --------------------------------------------------------------------------
# ensure_cluster_on_default_port reads `pg_lsclusters -h`, so a stub standing in
# for it is passed by name. The layouts below are real output from ubuntu:24.04
# with postgresql-16 installed and postgresql-17 added afterwards.
# --------------------------------------------------------------------------
DB_PORT=5432
mk_lsclusters() {   # mk_lsclusters <name> <lines...>
  local bin="$CLUSTER_BIN_DIR/$1"; shift
  { echo '#!/bin/sh'; printf 'cat <<%s\n%s\n%s\n' EOF "$*" EOF; } > "$bin"
  chmod +x "$bin"
}
CLUSTER_BIN_DIR="$(mktemp -d)"
PATH="$CLUSTER_BIN_DIR:$PATH"

echo "52. a bumped PG_MAJOR that would land on a second port is refused"
# pg_createcluster allocates the first free port from 5432 up, so installing a
# new major version beside an existing one puts it on 5433 — while psql, the
# database, the backups and DATABASE_URL all keep using 5432. Provisioning would
# report "PostgreSQL 17" with the app still on 16 and nothing failing.
PG_MAJOR=17
mk_lsclusters pg_ls_16only '16  main    5432 online postgres /var/lib/postgresql/16/main /var/log/x'
out="$( (ensure_cluster_on_default_port pg_ls_16only) 2>&1 )"
chk "exits non-zero" 1 "$?"
case "$out" in
  *"already serves 5432"*"pg_upgradecluster"*)
    echo "  ok   names the version holding the port and how to migrate" ;;
  *) echo "  FAIL unhelpful message: $out"; fail=1 ;;
esac

echo "53. an existing cluster of the RIGHT version on the wrong port is refused too"
# The other way in: the operator moved 17 to 5433 by hand, or a previous run
# created it beside something since removed. Everything downstream names 5432.
mk_lsclusters pg_ls_17_5433 '17  main    5433 online postgres /var/lib/postgresql/17/main /var/log/x'
out="$( (ensure_cluster_on_default_port pg_ls_17_5433) 2>&1 )"
chk "exits non-zero" 1 "$?"
case "$out" in
  *"listens on 5433, not 5432"*) echo "  ok   says which port it found" ;;
  *) echo "  FAIL unhelpful message: $out"; fail=1 ;;
esac

echo "54. the supported layouts are allowed through"
# A bare host (no postgresql-common yet) and the ordinary re-run must not be
# refused — this guard exists to catch a silent miss, not to block convergence.
out="$( (ensure_cluster_on_default_port pg_ls_absent) 2>&1 )"
chk "no clusters at all: proceeds" 0 "$?"
chk "and says nothing"             "" "$out"
mk_lsclusters pg_ls_17ok '17  main    5432 online postgres /var/lib/postgresql/17/main /var/log/x'
out="$( (ensure_cluster_on_default_port pg_ls_17ok) 2>&1 )"
chk "the ordinary re-run: proceeds" 0 "$?"
chk "and says nothing"              "" "$out"
# A leftover cluster parked off the default port is not ours to adjudicate, so
# long as PG_MAJOR is the one actually serving the app.
mk_lsclusters pg_ls_both "$(printf '17  main    5432 online postgres /a /b\n16  main    5433 online postgres /c /d')"
out="$( (ensure_cluster_on_default_port pg_ls_both) 2>&1 )"
chk "ours on 5432 beside an idle old one: proceeds" 0 "$?"

# --------------------------------------------------------------------------
# ensure_swapfile. swapon/swapoff/mkswap are stubbed and the swap file is an
# ordinary file in a temp dir, so the size on disk is what the function reads —
# the real thing it compares against SWAP_SIZE_MB.
#
# SWAPPED_ON is the kernel's view; the stubs mutate it, so "did the size change"
# and "is it still enabled" are separate assertions rather than one.
# --------------------------------------------------------------------------
SWAPPED_ON=""
SWAPOFF_FAILS=""
# shellcheck disable=SC2329  # called by ensure_swapfile, eval'd from the script
swapon() {
  if [ "${1:-}" = --show=NAME ]; then printf '%s\n' "$SWAPPED_ON"; return 0; fi
  SWAPPED_ON="$1"
}
# shellcheck disable=SC2329  # called by ensure_swapfile, eval'd from the script
swapoff() { [ -z "$SWAPOFF_FAILS" ] || return 1; SWAPPED_ON=""; return 0; }
# shellcheck disable=SC2329  # called by ensure_swapfile, eval'd from the script
mkswap() { :; }
# DISK_FREE_MIB caps what the filesystem will accept; "" means unlimited. The
# two stubs fail the way the real tools were observed to fail on a full tmpfs:
# fallocate refuses outright and writes nothing, dd writes what fits and then
# returns non-zero — so the partial file is a real partial file, which is the
# thing the caller has to not leave at the live path.
DISK_FREE_MIB=""
# shellcheck disable=SC2329  # called by allocate_swapfile, eval'd from the script
fallocate() {
  local mib="${2%M}"
  [ -z "$DISK_FREE_MIB" ] || [ "$mib" -le "$DISK_FREE_MIB" ] || return 1
  : > "$3"
  command dd if=/dev/zero of="$3" bs=1048576 count="$mib" status=none 2>/dev/null
}
# shellcheck disable=SC2329  # called by allocate_swapfile, eval'd from the script
dd() {
  local a path="" mib=""
  for a in "$@"; do
    case "$a" in of=*) path="${a#of=}" ;; count=*) mib="${a#count=}" ;; esac
  done
  if [ -n "$DISK_FREE_MIB" ] && [ "$mib" -gt "$DISK_FREE_MIB" ]; then
    command dd if=/dev/zero of="$path" bs=1048576 count="$DISK_FREE_MIB" status=none 2>/dev/null
    return 1
  fi
  command dd if=/dev/zero of="$path" bs=1048576 count="$mib" status=none 2>/dev/null
}
LOGGED=""
# shellcheck disable=SC2329  # called by ensure_swapfile, eval'd from the script
log() { LOGGED="$LOGGED $*"; }
swap_mib() { echo $(( $(stat -c %s "$1" 2>/dev/null || stat -f %z "$1") / 1048576 )); }

new_swap_env() {   # <existing-MiB>  ("" for no file)
  DISK_FREE_MIB=""   # reset before the setup dd, not only after it
  d=$(mktemp -d); SWAPFILE="$d/swapfile"; FSTAB="$d/fstab"
  printf 'UUID=xxx / ext4 defaults 0 1\n' > "$FSTAB"
  if [ -n "$1" ]; then
    dd if=/dev/zero of="$SWAPFILE" bs=1048576 count="$1" status=none
    SWAPPED_ON="$SWAPFILE"
    ensure_block "$FSTAB" swap "$SWAPFILE none swap sw 0 0"
  else
    SWAPPED_ON=""
  fi
  LOGGED=""; SWAPOFF_FAILS=""; DISK_FREE_MIB=""
}

echo "55. a first run creates the swap file at the configured size"
new_swap_env ""
SWAP_SIZE_MB=8 ensure_swapfile "$SWAPFILE" "$FSTAB"
chk "created at 8MiB"   8 "$(swap_mib "$SWAPFILE")"
chk "enabled"           "$SWAPFILE" "$SWAPPED_ON"
chk "mode 0600"         "600" "$(file_mode "$SWAPFILE")"
chk "fstab entry"       1 "$(grep -c "^$SWAPFILE none swap" "$FSTAB")"

echo "56. an unchanged SWAP_SIZE_MB rewrites nothing"
new_swap_env 8
ino="$(inode "$SWAPFILE")"
SWAP_SIZE_MB=8 ensure_swapfile "$SWAPFILE" "$FSTAB"
chk "same inode"  "$ino" "$(inode "$SWAPFILE")"
chk "still on"    "$SWAPFILE" "$SWAPPED_ON"
chk "silent"      "" "$LOGGED"

echo "57. a raised SWAP_SIZE_MB actually resizes, rather than being skipped"
# The whole finding: the old guard asked "is swap on?" and returned, so an
# operator raising this after an OOM got a successful run and the old headroom.
new_swap_env 4
SWAP_SIZE_MB=12 ensure_swapfile "$SWAPFILE" "$FSTAB"
chk "grown to 12MiB"  12 "$(swap_mib "$SWAPFILE")"
chk "re-enabled"      "$SWAPFILE" "$SWAPPED_ON"
case "$LOGGED" in
  *"resized"*"4MiB to 12MiB"*) echo "  ok   says what it changed" ;;
  *) echo "  FAIL silent or vague: $LOGGED"; fail=1 ;;
esac

echo "58. a lowered SWAP_SIZE_MB shrinks it too"
new_swap_env 16
SWAP_SIZE_MB=4 ensure_swapfile "$SWAPFILE" "$FSTAB"
chk "shrunk to 4MiB" 4 "$(swap_mib "$SWAPFILE")"
chk "re-enabled"     "$SWAPFILE" "$SWAPPED_ON"

echo "59. SWAP_SIZE_MB=0 actually disables swap"
new_swap_env 8
SWAP_SIZE_MB=0 ensure_swapfile "$SWAPFILE" "$FSTAB"
chk "file removed"      0 "$([ -e "$SWAPFILE" ] && echo 1 || echo 0)"
chk "swap off"          "" "$SWAPPED_ON"
chk "no fstab swap line" 0 "$(grep -c 'none swap' "$FSTAB")"
chk "other mounts kept"  1 "$(grep -c '^UUID=xxx' "$FSTAB")"
# The marker stays so a later non-zero run converges this block rather than
# appending a second one.
SWAP_SIZE_MB=8 ensure_swapfile "$SWAPFILE" "$FSTAB"
chk "one managed block after re-enabling" 1 "$(grep -c '# BEGIN collavre:swap' "$FSTAB")"
chk "swap line back"                      1 "$(grep -c 'none swap' "$FSTAB")"

echo "60. SWAP_SIZE_MB=0 on a host that never had swap is a no-op"
new_swap_env ""
SWAP_SIZE_MB=0 ensure_swapfile "$SWAPFILE" "$FSTAB"
chk "nothing created" 0 "$([ -e "$SWAPFILE" ] && echo 1 || echo 0)"
chk "silent"          "" "$LOGGED"

echo "61. a swapoff that fails leaves the old swap running and says so"
# Low memory is exactly when swapoff fails and exactly when this setting is
# being changed, so it must not abandon a provisioning run.
new_swap_env 4
SWAPOFF_FAILS=1
SWAP_SIZE_MB=12 ensure_swapfile "$SWAPFILE" "$FSTAB"
chk "returns success" 0 "$?"
chk "size unchanged"  4 "$(swap_mib "$SWAPFILE")"
chk "still enabled"   "$SWAPFILE" "$SWAPPED_ON"
case "$LOGGED" in
  *"WARNING"*"did NOT take effect"*) echo "  ok   operator told it did not take" ;;
  *) echo "  FAIL silent: $LOGGED"; fail=1 ;;
esac

echo "61a. the swap it keeps is also made to survive a reboot"
# Codex's shape: an active swapfile with no fstab entry — an operator who ran
# `swapon` by hand, or a run interrupted between swapon and ensure_block. The
# matching-size path was fixed for this; the failure paths that *retain* swap
# were not, so a failed resize failed twice over — the size did not change, and
# what was kept instead was kept only until the next restart. On a low-memory
# instance a reboot is when the headroom is most needed.
new_swap_env 4
printf 'UUID=xxx / ext4 defaults 0 1\n' > "$FSTAB"   # active, but not persisted
SWAPOFF_FAILS=1
SWAP_SIZE_MB=12 ensure_swapfile "$SWAPFILE" "$FSTAB"
chk "returns success"       0 "$?"
chk "old swap still on"     "$SWAPFILE" "$SWAPPED_ON"
chk "and now in fstab"      1 "$(grep -c "^$SWAPFILE none swap" "$FSTAB")"
chk "one managed block"     1 "$(grep -c '# BEGIN collavre:swap' "$FSTAB")"
chk "operator's own mount untouched" 1 "$(grep -c '^UUID=xxx' "$FSTAB")"

echo "62. a resize that does not fit puts the previous swap back"
# Growing means freeing the old file first, so an allocation that fails would
# otherwise end the run with no swap at all — worse than it started, on the
# low-memory host the setting exists for. The old size is known to fit.
new_swap_env 8
DISK_FREE_MIB=20
SWAP_SIZE_MB=64 ensure_swapfile "$SWAPFILE" "$FSTAB"
chk "run continues"        0 "$?"
chk "previous size back"   8 "$(swap_mib "$SWAPFILE")"
chk "swap re-enabled"      "$SWAPFILE" "$SWAPPED_ON"
chk "no truncated file"    0 "$(( $(swap_mib "$SWAPFILE") == 20 ? 1 : 0 ))"
case "$LOGGED" in
  *"WARNING"*"did NOT take effect"*"8MiB swap is back"*)
    echo "  ok   operator told the raise did not take, and what is running" ;;
  *) echo "  FAIL silent or claims success: $LOGGED"; fail=1 ;;
esac

echo "62a. the swap it restores is also made to survive a reboot"
# The other branch that retains swap and returned without converging fstab.
new_swap_env 8
printf 'UUID=xxx / ext4 defaults 0 1\n' > "$FSTAB"   # active, but not persisted
DISK_FREE_MIB=20
SWAP_SIZE_MB=64 ensure_swapfile "$SWAPFILE" "$FSTAB"
chk "run continues"      0 "$?"
chk "previous size back" 8 "$(swap_mib "$SWAPFILE")"
chk "and now in fstab"   1 "$(grep -c "^$SWAPFILE none swap" "$FSTAB")"
chk "one managed block"  1 "$(grep -c '# BEGIN collavre:swap' "$FSTAB")"

echo "63. a first run that cannot allocate dies rather than reporting success"
# have=0, so there is nothing to restore; the run must stop loudly instead of
# continuing on a swapfile that was never made.
new_swap_env ""
DISK_FREE_MIB=20
out="$( (SWAP_SIZE_MB=64 ensure_swapfile "$SWAPFILE" "$FSTAB") 2>&1 )"
chk "exits non-zero" 1 "$?"
chk "no partial swapfile left" 0 "$([ -e "$SWAPFILE" ] && echo 1 || echo 0)"
case "$out" in
  *"could not allocate 64MiB"*"no swap"*) echo "  ok   says what state the host is in" ;;
  *) echo "  FAIL unhelpful message: $out"; fail=1 ;;
esac
DISK_FREE_MIB=""

echo "63a. swap that is active but absent from fstab gets its entry"
# The size matches, so the early return fires — but this host loses its swap at
# the next reboot, which is when a low-memory instance most needs it. Reached by
# an operator who ran swapon by hand, or a run interrupted between swapon and
# the fstab write below it.
new_swap_env ""
dd if=/dev/zero of="$SWAPFILE" bs=1048576 count=8 status=none
SWAPPED_ON="$SWAPFILE"                    # active, but new_swap_env wrote no entry
ino="$(inode "$SWAPFILE")"
SWAP_SIZE_MB=8 ensure_swapfile "$SWAPFILE" "$FSTAB"
chk "fstab entry written"   1 "$(grep -c "^$SWAPFILE none swap" "$FSTAB")"
chk "the file is untouched" "$ino" "$(inode "$SWAPFILE")"
chk "still enabled"         "$SWAPFILE" "$SWAPPED_ON"
chk "one managed block"     1 "$(grep -c '# BEGIN collavre:swap' "$FSTAB")"

echo "63b. and the ordinary re-run stays a no-op"
new_swap_env 8
SWAP_SIZE_MB=8 ensure_swapfile "$SWAPFILE" "$FSTAB"
chk "still one managed block" 1 "$(grep -c '# BEGIN collavre:swap' "$FSTAB")"
chk "still one swap line"     1 "$(grep -c "^$SWAPFILE none swap" "$FSTAB")"
chk "silent"                  "" "$LOGGED"

echo "63c. SWAP_SIZE_MB=0 clears a stale fstab line, but writes none on a bare host"
new_swap_env ""
ensure_block "$FSTAB" swap "$SWAPFILE none swap sw 0 0"   # file deleted by hand
SWAP_SIZE_MB=0 ensure_swapfile "$SWAPFILE" "$FSTAB"
chk "the stale line is gone" 0 "$(grep -c 'none swap' "$FSTAB")"
new_swap_env ""
SWAP_SIZE_MB=0 ensure_swapfile "$SWAPFILE" "$FSTAB"
chk "no block added to a bare host" 0 "$(grep -c '# BEGIN collavre:swap' "$FSTAB")"

unset -f swapon swapoff mkswap fallocate dd

echo "64. an unsupported DB_PORT is refused before anything is installed"
# Nothing here writes postgresql.conf, and pg_createcluster takes the first free
# port from 5432 — so an overridden DB_PORT is named by DATABASE_URL, the ufw
# rule and the backup while the cluster listens on 5432 regardless.
guard="$(awk '/^\[ "\$DB_PORT" = "5432" \]/, /different port\.\"$/' "$SRC")"
# The range end must be the guard's own last line; an unmatched end pattern
# would run to EOF and "pass" by executing half the script.
chk "extracted just the guard" 5 "$(printf '%s\n' "$guard" | wc -l | tr -d ' ')"
case "$guard" in
  *'die'*) echo "  ok   the guard is in the script" ;;
  *) echo "  FAIL no DB_PORT guard found in $SRC"; fail=1 ;;
esac
out="$( (DB_PORT=5433 eval "$guard") 2>&1 )"
chk "exits non-zero" 1 "$?"
case "$out" in
  *"DB_PORT=5433 is not supported"*"still listen on 5432"*)
    echo "  ok   says what would have happened" ;;
  *) echo "  FAIL unhelpful message: $out"; fail=1 ;;
esac
out="$( (DB_PORT=5432 eval "$guard") 2>&1 )"
chk "the default proceeds" 0 "$?"
chk "and says nothing"     "" "$out"

# --------------------------------------------------------------------------
# ensure_docker_log_caps. Real jq; the file is a temp path.
# --------------------------------------------------------------------------
caps_of() { jq -c '."log-opts"' "$1"; }

echo "65. a host with no daemon.json gets the caps written"
d=$(mktemp -d); f="$d/daemon.json"; LOGGED=""
ensure_docker_log_caps "$f"
chk "reports it changed the file" 1 "$DAEMON_JSON_CHANGED"
chk "caps present" '{"max-size":"10m","max-file":"3"}' "$(caps_of "$f")"
chk "valid JSON"   0 "$(jq empty "$f" >/dev/null 2>&1; echo $?)"

echo "66. an existing daemon.json without caps has them merged in, not clobbered"
# The finding: the old condition skipped the whole block whenever the file
# existed, so a by-hand run on an existing instance left logs uncapped and
# still reported Docker as configured.
d=$(mktemp -d); f="$d/daemon.json"; LOGGED=""
printf '{"insecure-registries":["r.internal:5000"],"live-restore":true}\n' > "$f"
ensure_docker_log_caps "$f"
chk "reports it changed the file" 1 "$DAEMON_JSON_CHANGED"
chk "caps added"   '{"max-size":"10m","max-file":"3"}' "$(caps_of "$f")"
chk "driver set"   'json-file' "$(jq -r '."log-driver"' "$f")"
chk "operator's registries kept" '["r.internal:5000"]' "$(jq -c '."insecure-registries"' "$f")"
chk "operator's live-restore kept" 'true' "$(jq -r '."live-restore"' "$f")"

echo "67. existing caps are left exactly as the operator set them"
d=$(mktemp -d); f="$d/daemon.json"; LOGGED=""
printf '{"log-driver":"json-file","log-opts":{"max-size":"50m","max-file":"10"}}\n' > "$f"
before="$(cat "$f")"
ensure_docker_log_caps "$f"
chk "reports no change" 0 "$DAEMON_JSON_CHANGED"
chk "byte-identical"    "$before" "$(cat "$f")"

echo "67a. Docker's unlimited max-size is repaired rather than accepted as a cap"
d=$(mktemp -d); f="$d/daemon.json"; LOGGED=""
printf '{"log-driver":"json-file","log-opts":{"max-size":"-1","max-file":"9"},"live-restore":true}\n' > "$f"
ensure_docker_log_caps "$f"
chk "reports it changed the file" 1 "$DAEMON_JSON_CHANGED"
chk "unlimited size replaced"     '10m' "$(jq -r '."log-opts"."max-size"' "$f")"
chk "rotation count set"          '3' "$(jq -r '."log-opts"."max-file"' "$f")"
chk "operator's other keys kept"  'true' "$(jq -r '."live-restore"' "$f")"

echo "68. a non-json-file driver is reported, not overridden"
# journald and local rotate on their own; forcing json-file would redirect an
# operator's logs rather than cap them.
for drv in journald local awslogs; do
  d=$(mktemp -d); f="$d/daemon.json"; LOGGED=""
  printf '{"log-driver":"%s"}\n' "$drv" > "$f"
  before="$(cat "$f")"
  ensure_docker_log_caps "$f"
  chk "no change for $drv" 0 "$DAEMON_JSON_CHANGED"
  chk "untouched: $drv"    "$before" "$(cat "$f")"
done
case "$LOGGED" in
  *"rotates on its own"*) echo "  ok   says why it left it alone" ;;
  *) echo "  FAIL silent: $LOGGED"; fail=1 ;;
esac

echo "69. an unparseable daemon.json is reported, never overwritten"
# It is the operator's file and Docker will not start until it is repaired;
# replacing it would destroy the evidence of what they meant.
d=$(mktemp -d); f="$d/daemon.json"; LOGGED=""
printf '{"log-driver": "json-file",,,\n' > "$f"
before="$(cat "$f")"
ensure_docker_log_caps "$f"
chk "reports no change" 0 "$DAEMON_JSON_CHANGED"
chk "untouched"         "$before" "$(cat "$f")"
case "$LOGGED" in
  *"WARNING"*"not valid JSON"*) echo "  ok   operator told" ;;
  *) echo "  FAIL silent: $LOGGED"; fail=1 ;;
esac

echo "70. a merged file is stable across re-runs"
d=$(mktemp -d); f="$d/daemon.json"; LOGGED=""
printf '{"live-restore":true}\n' > "$f"
ensure_docker_log_caps "$f"
after_first="$(cat "$f")"
ensure_docker_log_caps "$f"
chk "second run changes nothing" 0 "$DAEMON_JSON_CHANGED"
chk "byte-identical"             "$after_first" "$(cat "$f")"

echo "70a. existing containers are told when changed defaults take effect"
# This section needs the warning text on stdout; the next section restores the
# accumulator form used by the UFW tests.
log() { printf '%s\n' "$*"; }
docker() {
  [ "${1:-}" = ps ] || return 1
  case "${DOCKER_PS_RESULT:-}" in
    existing) printf 'container-id\n' ;;
    failure) return 1 ;;
  esac
}
out="$(DOCKER_PS_RESULT=existing warn_existing_containers_keep_log_config 2>&1)"
chk "existing containers are warned" 1 \
  "$(grep -c 'only after the next.*kamal.sh deploy.*recreates them' <<<"$out")"
out="$(DOCKER_PS_RESULT=empty warn_existing_containers_keep_log_config 2>&1)"
chk "a fresh host gets no warning" "" "$out"
out="$(DOCKER_PS_RESULT=failure warn_existing_containers_keep_log_config 2>&1)"
chk "an inspection failure is not read as no containers" 1 \
  "$(grep -c 'could.*not be inspected' <<<"$out")"
unset -f docker
unset DOCKER_PS_RESULT
restart_block="$(awk '
  index($0, "if [ \"$DAEMON_JSON_CHANGED\" -eq 1 ]; then") { p=1 }
  p { print }
  p && /^else$/ { exit }
' "$SRC")"
chk "the warning follows the Docker restart" 1 \
  "$(grep -c 'warn_existing_containers_keep_log_config' <<<"$restart_block")"

# --------------------------------------------------------------------------
# ensure_ufw_rule, revisited: a delete that FAILS must not advance the marker.
# --------------------------------------------------------------------------
UFW_CALLS=""
UFW_DELETE_FAILS=""
# shellcheck disable=SC2329  # called by ensure_ufw_rule, eval'd from the script
ufw() {
  UFW_CALLS="$UFW_CALLS|$*"
  [ "${1:-}" != delete ] || [ -z "$UFW_DELETE_FAILS" ] || return 1
  return 0
}
LOGGED=""
# shellcheck disable=SC2329  # called by ensure_ufw_rule, eval'd from the script
log() { LOGGED="$LOGGED $*"; }

echo "71. a delete that fails leaves the marker so the next run retries"
# `ufw delete` exits 0 even for a rule that was not there, so a non-zero status
# means it could not act and the old rule is still installed. Advancing the
# marker there loses the only record of it: the previous Docker subnet keeps
# reaching PostgreSQL for the life of the instance and no run can find it.
d=$(mktemp -d); st="$d/ufw_postgres"
old="allow from 172.17.0.0/16 to 172.17.0.1 port 5432 proto tcp"
new="allow from 10.200.0.0/16 to 172.18.0.1 port 5432 proto tcp"
printf '%s\n' "$old" > "$st"
UFW_CALLS=""; LOGGED=""; UFW_DELETE_FAILS=1
ensure_ufw_rule postgres "$new" "$st"
chk "returns success"        0 "$?"
chk "new rule still added"   1 "$(printf '%s' "$UFW_CALLS" | grep -c '|allow from 10.200.0.0/16')"
chk "marker NOT advanced"    "$old" "$(cat "$st")"
case "$LOGGED" in
  *"WARNING"*"still"*"in force"*) echo "  ok   operator told, with the command to fix it" ;;
  *) echo "  FAIL silent or vague: $LOGGED"; fail=1 ;;
esac
# and the retry works once ufw can act again
UFW_CALLS=""; LOGGED=""; UFW_DELETE_FAILS=""
ensure_ufw_rule postgres "$new" "$st"
chk "retry withdraws the old rule" 1 "$(printf '%s' "$UFW_CALLS" | grep -c "|delete $old")"
chk "marker advanced now"          "$new" "$(cat "$st")"

echo "72. the replacement is added before the predecessor is withdrawn"
# An interrupted run must never leave the host with neither rule.
d=$(mktemp -d); st="$d/ufw_postgres"
printf '%s\n' "$old" > "$st"
UFW_CALLS=""; LOGGED=""; UFW_DELETE_FAILS=""
ensure_ufw_rule postgres "$new" "$st"
case "$UFW_CALLS" in
  "|allow from 10.200.0.0/16"*"|delete allow from 172.17.0.0/16"*)
    echo "  ok   add precedes delete" ;;
  *) echo "  FAIL wrong order: $UFW_CALLS"; fail=1 ;;
esac
unset -f ufw

# --------------------------------------------------------------------------
# install_deploy_ssh_dir. `id` and `install` are stubbed so the group the
# function actually asks for is what gets recorded, and so an unknown group
# fails the way the real `install` does.
# --------------------------------------------------------------------------
PRIMARY_GROUP=collavre
KNOWN_GROUPS="collavre users ubuntu"
INSTALL_LOG="$(mktemp)"
# shellcheck disable=SC2329  # called by install_deploy_ssh_dir, eval'd from the script
id() { [ "${1:-}" = -gn ] || { command id "$@"; return; }; printf '%s\n' "$PRIMARY_GROUP"; }
# shellcheck disable=SC2329  # called by install_deploy_ssh_dir, eval'd from the script
install() {
  local g="" args=("$@") i
  for (( i = 0; i < ${#args[@]} - 1; i++ )); do
    [ "${args[i]}" = -g ] && g="${args[i+1]}"
  done
  # The function runs inside $( ), so a variable assignment would die with the
  # subshell. Recorded to a file for the same reason as the mktemp template.
  printf '%s\n' "$*" > "$INSTALL_LOG"
  case " $KNOWN_GROUPS " in
    *" $g "*) return 0 ;;
    *) echo "install: invalid group '$g'" >&2; return 1 ;;
  esac
}

echo "73. the deploy user's own primary group is used, not one named after it"
# APP_SSH_USER may name an account that already exists — the cloud user, or one
# made with `useradd -g users deploybot`. Assuming a same-named group makes
# `install` exit non-zero, and under set -e that ends the run before authorized
# keys, Docker and PostgreSQL.
PRIMARY_GROUP=users
out="$(install_deploy_ssh_dir deploybot /home/deploybot)"
chk "the call succeeded"      0 "$?"
chk "echoes the real group"   "users" "$out"
INSTALL_CALL="$(cat "$INSTALL_LOG")"
case "$INSTALL_CALL" in
  *"-g users"*) echo "  ok   install was given the account's own group" ;;
  *) echo "  FAIL install called with: $INSTALL_CALL"; fail=1 ;;
esac
case "$INSTALL_CALL" in
  *"-m 0700"*"-o deploybot"*"/home/deploybot/.ssh"*)
    echo "  ok   still 0700 and owned by the account" ;;
  *) echo "  FAIL wrong mode/owner/path: $INSTALL_CALL"; fail=1 ;;
esac

echo "74. the ordinary case — a matching group — is unchanged"
PRIMARY_GROUP=collavre
out="$(install_deploy_ssh_dir collavre /home/collavre)"
chk "succeeds"      0 "$?"
chk "group echoed"  "collavre" "$out"

echo "75. a genuinely failing install is reported, not papered over by the printf"
PRIMARY_GROUP=nosuchgroup
out="$(install_deploy_ssh_dir deploybot /home/deploybot 2>/dev/null)"
chk "returns non-zero" 1 "$?"
chk "no group echoed"  "" "$out"
unset -f id install

# --------------------------------------------------------------------------
# Per-account key records. The real install_authorized_keys and
# revoke_prior_ssh_key, driven through a rotation that leaves one account and
# comes back to it.
# --------------------------------------------------------------------------
echo "76. moving APP_SSH_USER away and back still withdraws that account's old key"
# The global marker advances with each run, so on the way back it names a key
# that was never in this file — while the same re-run has just put the account
# back in docker and sudoers.
STATE_DIR="$(mktemp -d)"
KEY_A="ssh-ed25519 AAAAKEYA first@laptop"
KEY_B="ssh-ed25519 AAAAKEYB second@laptop"
KEY_C="ssh-ed25519 AAAAKEYC third@laptop"
collavre_keys="$(mktemp)"; deploybot_keys="$(mktemp)"

run_key_step() {   # <user> <key> <authorized_keys>
  APP_SSH_USER="$1" SSH_PUBLIC_KEY="$2"
  install_authorized_keys "$3" /nonexistent
  if [ -f "$STATE_DIR/ssh_public_key" ] &&
     [ ! -f "$STATE_DIR/ssh_public_key.$APP_SSH_USER" ]; then
    mv "$STATE_DIR/ssh_public_key" "$STATE_DIR/ssh_public_key.$APP_SSH_USER"
  fi
  revoke_prior_ssh_key "$3"
}

run_key_step collavre  "$KEY_A" "$collavre_keys"
run_key_step deploybot "$KEY_B" "$deploybot_keys"
chk "key A stays while collavre is not the deploy user" \
    1 "$(grep -cxF "$KEY_A" "$collavre_keys")"
run_key_step collavre  "$KEY_C" "$collavre_keys"
chk "the key rotated TO is authorized" 1 "$(grep -cxF "$KEY_C" "$collavre_keys")"
chk "the key retired two rotations ago is gone" \
    0 "$(grep -cxF "$KEY_A" "$collavre_keys")"
chk "the other account is untouched" 1 "$(grep -cxF "$KEY_B" "$deploybot_keys")"

echo "77. a host with the old single marker adopts it rather than starting blank"
# Otherwise the first run after this change has no record, withdraws nothing,
# and the key it replaces stays authorized forever.
STATE_DIR="$(mktemp -d)"
legacy_keys="$(mktemp)"
printf '%s\n' "$KEY_A" > "$legacy_keys"
printf '%s\n' "$KEY_A" > "$STATE_DIR/ssh_public_key"     # written by an earlier revision
run_key_step collavre "$KEY_C" "$legacy_keys"
chk "the adopted predecessor is withdrawn" 0 "$(grep -cxF "$KEY_A" "$legacy_keys")"
chk "the successor is authorized"          1 "$(grep -cxF "$KEY_C" "$legacy_keys")"
chk "the global marker is gone"            0 "$([ -e "$STATE_DIR/ssh_public_key" ] && echo 1 || echo 0)"

# --- docs/deploy_to_lightsail.md, the PostgreSQL move ------------------------
#
# pg_restore --clean drops every object before it reloads one, so this recipe is
# an incident if it runs on a transfer that did not arrive. Run rather than read,
# for the same reason as the cutover above.

move="$(extract_recipe 'move_status=')"
case "$move" in
  *pg_dump*scp*pg_restore*) : ;;
  *) echo "could not extract the PostgreSQL-move recipe from $DOC — has it moved?" >&2
     exit 1 ;;
esac

# The ssh stub runs the remote command for real against a sandbox stand-in for
# /tmp, so the `&&` chain, the rename and the `rm` are exercised rather than
# pattern-matched. FAIL_DUMP / FAIL_XFER / FAIL_RESTORE choose the failing step.
run_move() {
  local work; work="$(mktemp -d)"
  # REUSE_REMOTE keeps the instance's /tmp across two calls, which is what the
  # stale-snapshot case needs: one run leaves a dump behind, the next must not
  # be able to restore it.
  export REMOTE="${REUSE_REMOTE:-$work/remote}"
  mkdir -p "$REMOTE" "$work/bin" "$work/rbin"
  printf '%s' "$move" |
    sed -e 's/<instance-ip>/203.0.113.10/g' -e 's/<deploy-user>/collavre/g' \
        -e 's/<db-user>/collavre_user/g' -e 's/<db-name>/collavre_production/g' \
    > "$work/recipe.sh"

  cat > "$work/bin/psql" <<'STUB'
#!/usr/bin/env bash
echo psql >>"$TRACE"
STUB
  cat > "$work/bin/pg_dump" <<'STUB'
#!/usr/bin/env bash
echo pg_dump >>"$TRACE"
[ -z "$FAIL_DUMP" ] || exit 1
out=""; while [ $# -gt 0 ]; do [ "$1" = -f ] && out="$2"; shift; done
printf 'DUMP-%s\n' "${DUMP_TAG:-fresh}" > "$out"
STUB
  cat > "$work/bin/scp" <<'STUB'
#!/usr/bin/env bash
dest="${2#*:}"
echo "scp:$dest" >>"$TRACE"
[ -z "$FAIL_XFER" ] || exit 1
cp "$1" "${dest/\/tmp\//$REMOTE/}"
STUB
  cat > "$work/bin/ssh" <<'STUB'
#!/usr/bin/env bash
shift                                   # drop user@host; the rest is the command
cmd="$*"; cmd="${cmd//\/tmp\//$REMOTE/}"
echo ssh >>"$TRACE"
PATH="$RBIN:$PATH" bash -c "$cmd"
STUB
  # The restore runs on the instance as the `postgres` superuser over the local
  # socket, so the remote sandbox needs a sudo of its own. It records who it was
  # asked to become rather than silently stripping the argument: "restored as
  # postgres" is the property that replaced a connection URL carrying the app's
  # password, and a stub that dropped `-u` would let a recipe that went back to
  # running as the deploy user pass here.
  cat > "$work/rbin/sudo" <<'STUB'
#!/usr/bin/env bash
if [ "${1:-}" = -u ]; then echo "sudo-u:$2" >>"$TRACE"; shift 2; fi
exec "$@"
STUB
  cat > "$work/rbin/pg_restore" <<'STUB'
#!/usr/bin/env bash
for a in "$@"; do case "$a" in *collavre.dump) echo "PG_RESTORE:$(cat "$a" 2>&1)" >>"$TRACE" ;; esac; done
[ -z "$FAIL_RESTORE" ] || exit 1
STUB
  chmod +x "$work/bin"/* "$work/rbin"/*

  TRACE="$work/trace"; : > "$TRACE"
  export TRACE RBIN="$work/rbin"
  export FAIL_DUMP="${FAIL_DUMP:-}" FAIL_XFER="${FAIL_XFER:-}" FAIL_RESTORE="${FAIL_RESTORE:-}"
  MOVE_OUT="$(cd "$work" && PATH="$work/bin:$PATH" bash ./recipe.sh 2>&1)"
  MOVE_TRACE="$(paste -sd'|' "$TRACE")"
  # shellcheck disable=SC2119  # the real sort; the stub below is scoped to case 84
  MOVE_LEFT="$(find "$REMOTE" -maxdepth 1 -type f -exec basename {} \; | sort | paste -sd, -)"
  rm -rf "$work"
}

echo "78. a clean move transfers, restores, and cleans up"
FAIL_DUMP='' FAIL_XFER='' FAIL_RESTORE='' DUMP_TAG=fresh run_move
chk "staged under .incoming"  1 "$(grep -c 'scp:/tmp/collavre.dump.incoming' <<<"${MOVE_TRACE//|/$'\n'}")"
chk "restored the new dump"   1 "$(grep -c 'PG_RESTORE:DUMP-fresh' <<<"${MOVE_TRACE//|/$'\n'}")"
chk "nothing left behind"     ""  "$MOVE_LEFT"
chk "restored as postgres"    1 "$(grep -c '^sudo-u:postgres$' <<<"${MOVE_TRACE//|/$'\n'}")"

echo "78a. the move never asks for the password to be pasted into a URL"
# $DB_PASSWORD is stored raw and appears encoded only inside DATABASE_URL, so a
# URL built by hand from the two files this page tells you to read is wrong
# whenever the operator chose their own password. Measured against libpq 14.15,
# the three that fail do so after the scp with the source already quiesced —
# and `pa%41ss` does not fail at all, it authenticates as "paAss".
#
#   p@ss      could not translate host name "ss@127.0.0.1"
#   p/ss      could not translate host name "ss"
#   p%ss      invalid percent-encoded token
#   pa%41ss   connects, as a different password
#
# Asserted against the recipe text rather than by running it, because the defect
# is a value the operator is instructed to type: no stub can fail on a password
# the harness never had. Both spellings are checked — the placeholder this page
# used and a URI scheme anywhere in the block — so neither a rename of the
# placeholder nor a differently-worded URL brings it back unnoticed.
chk "no password placeholder" 0 "$(grep -c '<password>' <<<"$move")"
chk "no connection URI"       0 "$(grep -c 'postgres\(ql\)\?://' <<<"$move")"
# The page has to keep saying why, or the next edit re-derives the URL as the
# obvious way to name a database.
chk "and the page says why"   1 \
  "$(grep -c 'invalid percent-encoded token' "$DOC")"

echo "78b. the deploy section does not ask for a hand-composed DATABASE_URL"
# Same defect as 78a one consumer over: section 4's .env.production is the one
# place on this page the operator *types* a DATABASE_URL, and it carried a
# <password> slot. The parser there is Rails', not libpq's, and it fails in the
# same misdirected way. Measured against
# ActiveRecord::DatabaseConfigurations::ConnectionUrlResolver:
#
#   p@ss        URI::InvalidURIError            (likewise p#ss, p?ss, p%ss)
#   p@ss/word   parses — host "ss", database "word@172.17.0.1:5432/..."
#   pa%41ss     parses — password "paAss"
#
# So the page's blanket claim that any of those six characters aborts the boot
# with URI::InvalidURIError was wrong for the pair most likely to occur
# together — and wrong about this page's *own* worked example, p@ss/word, which
# resolves a hostname instead of raising.
#
# Asserted on the dotenv block rather than the whole page: section 3 shows the
# same URL shape to say where PostgreSQL listens, which is a description and not
# an instruction to fill one in. There is exactly one dotenv block on the page.
deploy_env="$(awk '/^```dotenv$/{f=1;next} f&&/^```$/{exit} f' "$DOC")"
chk "there is a dotenv block"  1 "$([ -n "$deploy_env" ] && echo 1 || echo 0)"
chk "no password placeholder"  0 "$(grep -c '<password>' <<<"$deploy_env")"
chk "no hand-built URI"        0 "$(grep -c 'postgres\(ql\)\?://' <<<"$deploy_env")"
chk "names the summary file"   1 "$(grep -c 'summary file' <<<"$deploy_env")"
# And the corrected claim has to stay corrected: the two silent cases are what
# make copying the summary file load-bearing rather than merely tidy. Scoped to
# the Rails block — `pa%41ss` is also measured against libpq further down the
# page, and the whole-page count would then pass for the wrong reason.
rails_urls="$(awk '/ConnectionUrlResolver/{f=1;next} f&&/^```$/{n++; if(n==2) exit; next} f&&n==1' "$DOC")"
chk "states the silent parse"  1 "$(grep -c 'host "ss"' <<<"$rails_urls")"
chk "states the silent decode" 1 "$(grep -c 'password "paAss"' <<<"$rails_urls")"
chk "no blanket abort claim"   0 \
  "$(grep -c 'every Rails command in' "$DOC")"

echo "79. a failed pg_dump never reaches the transfer or the restore"
FAIL_DUMP=1 FAIL_XFER='' FAIL_RESTORE='' run_move
chk "no transfer"             0 "$(grep -c '^scp:' <<<"${MOVE_TRACE//|/$'\n'}")"
chk "no restore"              0 "$(grep -c '^PG_RESTORE' <<<"${MOVE_TRACE//|/$'\n'}")"
chk "operator told"           1 "$(grep -c 'MOVE FAILED' <<<"$MOVE_OUT")"

echo "80. a failed transfer cannot restore the snapshot a previous attempt kept"
# The retained /tmp/collavre.dump is deliberate — it makes a retry cheap. As
# separate statements the next failed scp would restore *it*, report success and
# delete it: a silent rollback to older data, with the evidence removed.
stale_remote="$(mktemp -d)"
REUSE_REMOTE="$stale_remote" FAIL_DUMP='' FAIL_XFER='' FAIL_RESTORE=1 DUMP_TAG=stale run_move
chk "the first attempt leaves a dump" "collavre.dump" "$MOVE_LEFT"
REUSE_REMOTE="$stale_remote" FAIL_DUMP='' FAIL_XFER=1 FAIL_RESTORE='' DUMP_TAG=fresh run_move
chk "no restore ran at all"    0 "$(grep -c '^PG_RESTORE' <<<"${MOVE_TRACE//|/$'\n'}")"
chk "the stale snapshot was not restored" 0 \
  "$(grep -c 'PG_RESTORE:DUMP-stale' <<<"${MOVE_TRACE//|/$'\n'}")"
chk "nor deleted, so it is still evidence" "collavre.dump" "$MOVE_LEFT"
chk "operator told"            1 "$(grep -c 'MOVE FAILED' <<<"$MOVE_OUT")"
rm -rf "$stale_remote"; unset REUSE_REMOTE

echo "81. a failed restore keeps the dump and refuses to call the move done"
FAIL_DUMP='' FAIL_XFER='' FAIL_RESTORE=1 DUMP_TAG=fresh run_move
chk "the dump is kept for the retry" "collavre.dump" "$MOVE_LEFT"
chk "operator told it is unusable"   1 "$(grep -c 'not usable yet' <<<"$MOVE_OUT")"
chk "and told not to switch DNS"     1 "$(grep -c 'Do not point DNS' <<<"$MOVE_OUT")"

echo "82. the transfer never lands directly on the path the restore reads"
FAIL_DUMP='' FAIL_XFER='' FAIL_RESTORE='' run_move
# Asserted as "no transfer went anywhere else", not as "one went to .incoming":
# the pre-fix form sent to the directory /tmp/, which a check for the live
# filename alone would pass without ever staging anything.
chk "every transfer staged under .incoming" 0 \
  "$(grep '^scp:' <<<"${MOVE_TRACE//|/$'\n'}" | grep -cv '\.incoming$')"

# --- docs/deploy_to_lightsail.md, the §6 restore -----------------------------
#
# The stop runs on the workstation and this block on the instance, so there is
# no local exit status to gate on. The gate is a state instead: CONNECTION LIMIT
# 0 plus pg_terminate_backend, which holds for the whole restore rather than for
# the instant a count is taken. Verified on postgres:17 that a superuser is
# exempt from the limit (so pg_restore connects) while the app's role is refused
# with "too many connections" — including on a reconnect mid-restore, which is
# the case a point-in-time count cannot see.
#
# What is asserted here is which paths put the limit back, because both
# mistakes are silent and they point in opposite directions. Leaving it at 0
# after a restore that worked refuses the app at boot with an error that reads
# like a connection-pool problem rather than like a step this block forgot to
# undo. Re-opening after a restore that FAILED is worse: pg_restore --clean
# drops before it reloads, so the database is genuinely half-replaced, and the
# surviving container reconnects and writes into it. Measured on postgres:17
# with a dump truncated to 70%, `posts` came back with all 20,000 rows and
# `users` with none; a signup then landed and returned an id, and the retry the
# recipe itself recommends dropped it again with no error anywhere.

restore="$(extract_recipe 'restore_status=')"
case "$restore" in
  *CONNECTION\ LIMIT\ 0*pg_restore*CONNECTION\ LIMIT\ -1*) : ;;
  *) echo "could not extract the restore recipe from $DOC — has it moved?" >&2
     exit 1 ;;
esac

# LIVE is what the count query returns: "0" for a quiet database, a number for a
# container that survived the stop, "" for a check that itself failed.
run_restore() {
  local work; work="$(mktemp -d)"
  mkdir -p "$work/bin"
  printf '%s' "$restore" > "$work/recipe.sh"

  cat > "$work/bin/sudo" <<'STUB'
#!/usr/bin/env bash
while [ "${1:-}" = -u ] || [ "${1:-}" = postgres ]; do shift; done
exec "$@"
STUB
  # The recipe reads the configured DB_USER out of the state file the script
  # writes, so the harness has to answer for it. Unset APP_ROLE means the file
  # is absent — which is a case under test, not a default to paper over, since
  # "the question could not be answered" has to refuse just as "yes" does.
  cat > "$work/bin/cat" <<'STUB'
#!/usr/bin/env bash
if [ "${1:-}" = /var/lib/collavre/db_user ]; then
  [ -n "${APP_ROLE-}" ] || { echo "cat: $1: No such file or directory" >&2; exit 1; }
  printf '%s\n' "$APP_ROLE"; exit 0
fi
# Same for the database name: the recipe asks the host which database it is
# restoring rather than spelling one, so an absent file is a case under test —
# on a host that used DB_NAME or the rename procedure, a guess is the wrong
# database.
if [ "${1:-}" = /var/lib/collavre/db_name ]; then
  [ -n "${APP_DB-}" ] || { echo "cat: $1: No such file or directory" >&2; exit 1; }
  printf '%s\n' "$APP_DB"; exit 0
fi
exec /bin/cat "$@"
STUB
  # datconnlimit is modelled as state rather than as a canned answer, because
  # the whole point of reading it back is that it disagrees with the ALTER when
  # the ALTER did not take. FAIL_SHUT makes the ALTER a no-op — psql prints its
  # error and exits non-zero, which an interactive paste with no `set -e` walks
  # straight past, which is the case under test.
  # The cluster's own datconnlimit, which is not always -1: an operator may have
  # capped this database, and the recipe now has to put back what it found
  # rather than the default. PRIOR_LIMIT is that starting state.
  echo "${PRIOR_LIMIT--1}" > "$work/connlimit"
  # The prior read and the post-ALTER read-back are the same statement, so the
  # stub tells them apart by order rather than by text — which is also the only
  # way to model a prior read that failed while the ALTER still took.
  echo 0 > "$work/datconn_n"
  cat > "$work/bin/psql" <<'STUB'
#!/usr/bin/env bash
sql="${*: -1}"
# $app_db comes out of a state file, and DB_NAME accepts names that an unquoted
# identifier cannot carry — the launch script creates them through format('%I').
# Modelled at the parser rather than asserted about, so the case fails the way
# the cluster fails: syntax error, no state change, and a read-back that then
# disagrees with the ALTER.
case "$sql" in
  *"ALTER DATABASE"*)
    ident="${sql#*ALTER DATABASE }"; ident="${ident%% CONNECTION*}"
    case "$ident" in
      '"'*'"')      : ;;
      *[!a-z0-9_]*) echo 'ERROR:  syntax error at or near "-"' >&2; exit 1 ;;
    esac ;;
esac
case "$sql" in
  *"CONNECTION LIMIT 0"*)      echo "limit:0"        >>"$TRACE"
                               [ -n "$FAIL_SHUT" ] || echo 0 > "$CONNLIMIT"
                               [ -z "$FAIL_SHUT" ] || { echo 'ERROR:  database "x" does not exist' >&2; exit 1; } ;;
  # Any limit, not the literal -1: the re-open restores whatever the database
  # was at, so a stub that only knows -1 would pass a recipe that had gone back
  # to hard-coding it. What it wrote is what the case reads afterwards.
  *"CONNECTION LIMIT "*)       echo "limit:reopened" >>"$TRACE"
                               [ -z "$FAIL_REOPEN" ] ||
                                 { echo 'ERROR:  could not connect' >&2; exit 1; }
                               printf '%s\n' "${sql##*CONNECTION LIMIT }" > "$CONNLIMIT" ;;
  *rolsuper*)                  echo "rolsuper"       >>"$TRACE"; printf '%s' "$APP_SUPER" ;;
  *datconnlimit*)              n=$(cat "$DATCONN_N"); n=$((n + 1))
                               printf '%s' "$n" > "$DATCONN_N"
                               if [ "$n" = 1 ]; then
                                 echo "priorlimit" >>"$TRACE"
                                 # An empty answer with a non-zero status: what
                                 # a read that could not be answered looks like
                                 # through the recipe's own 2>/dev/null.
                                 [ -z "$FAIL_PRIOR_READ" ] || exit 1
                               else
                                 echo "readback" >>"$TRACE"
                                 # The ALTER committed and the confirmation did
                                 # not come back — the cluster restarted in
                                 # between, the connection dropped. Modelled
                                 # separately from FAIL_SHUT because the two
                                 # leave the database in opposite states while
                                 # looking identical from the recipe's side:
                                 # $shut is empty either way, and only one of
                                 # them has locked the app out.
                                 [ -z "$FAIL_READBACK" ] || exit 1
                               fi
                               cat "$CONNLIMIT" ;;
  *pg_terminate_backend*)      echo "terminate"      >>"$TRACE"; echo "${KILLED:-0}" ;;
  *"count(*)"*)                echo "count"          >>"$TRACE"; printf '%s' "$LIVE" ;;
  *usename*)                   echo "listing"        >>"$TRACE" ;;
esac
STUB
  cat > "$work/bin/pg_restore" <<'STUB'
#!/usr/bin/env bash
echo "PG_RESTORE_RAN" >>"$TRACE"
# Kept out of $TRACE, which is matched as a whole-sequence glob by a dozen
# cases above: an argument list spliced into it would be matched by their
# wildcards for the wrong reason. Its own file, read by case 139.
printf '%s\n' "$*" >"$RESTORE_ARGS"
[ -z "$FAIL_RESTORE" ] || exit 1
STUB
  chmod +x "$work/bin"/*

  TRACE="$work/trace"; : > "$TRACE"
  # ${LIVE-0}, not ${LIVE:-0}: the empty string is a case under test — it is what
  # a failed check returns — and :- would quietly turn it back into "0", making
  # the one assertion about a broken gate pass for the wrong reason.
  # APP_SUPER likewise takes ${x-y}, not ${x:-y}: an empty rolsuper is what a
  # role that does not exist, or a cluster that cannot be reached, comes back
  # as, and it must not be rewritten into the one value that lets the gate open.
  export TRACE LIVE="${LIVE-0}" KILLED="${KILLED:-0}" FAIL_RESTORE="${FAIL_RESTORE:-}" \
         FAIL_SHUT="${FAIL_SHUT:-}" FAIL_REOPEN="${FAIL_REOPEN:-}" \
         FAIL_PRIOR_READ="${FAIL_PRIOR_READ:-}" \
         FAIL_READBACK="${FAIL_READBACK:-}" \
         CONNLIMIT="$work/connlimit" DATCONN_N="$work/datconn_n" \
         RESTORE_ARGS="$work/restore_args" \
         APP_ROLE="${APP_ROLE-collavre_user}" APP_SUPER="${APP_SUPER-f}" \
         APP_DB="${APP_DB-collavre_production}"
  if [ -n "${RERUN:-}" ]; then
    # The retry the failure path invites, driven the way it is instructed: the
    # same shell, the block pasted a second time, with whatever failed the first
    # time now fixed. Sourced rather than run, because a shell variable
    # surviving between the two passes is the mechanism under test — the recipe
    # holds no state anywhere else, so a subshell per pass would model a fresh
    # shell and the assertion would be about a different instruction.
    cat > "$work/driver.sh" <<'DRV'
. ./recipe.sh
echo "--- pasted again in the same shell ---"
export FAIL_RESTORE='' FAIL_SHUT='' FAIL_PRIOR_READ='' FAIL_REOPEN='' FAIL_READBACK=''
. ./recipe.sh
DRV
    R_OUT="$(cd "$work" && PATH="$work/bin:$PATH" bash ./driver.sh 2>&1)"
  else
    R_OUT="$(cd "$work" && PATH="$work/bin:$PATH" bash ./recipe.sh 2>&1)"
  fi
  R_TRACE="$(paste -sd'|' "$TRACE")"
  # What the database is left at, which is the thing the operator meets at boot
  # — asserted directly rather than inferred from the statements that ran.
  R_LIMIT="$(cat "$work/connlimit")"
  R_RESTORE_ARGS="$(cat "$work/restore_args" 2>/dev/null || true)"
  rm -rf "$work"
}

echo "83. the restore shuts the database before it looks, and re-opens after"
LIVE=0 KILLED=2 FAIL_RESTORE='' run_restore
# The role check comes before the shut, and the shut before anything else the
# block does — asserted as the whole prefix rather than as "the first entry",
# so a step inserted between them fails here instead of silently reordering the
# gate. Nothing may precede the role check: it decides whether shutting the
# door means anything at all, and a refusal must leave the limit as it found it.
# The prior limit is read between them, and its position is not incidental: it
# has to be taken before the ALTER, because after it the previous value is gone.
chk "role checked, prior limit read, then shut, before all else" \
  "rolsuper|priorlimit|limit:0" "$(cut -d'|' -f1,2,3 <<<"$R_TRACE")"
chk "survivors terminated"   1 "$(grep -c '^terminate$' <<<"${R_TRACE//|/$'\n'}")"
# The order is the whole point: counting before the limit is applied only says
# the app happened to be between connections at that instant.
chk "counted only after the door was shut AND confirmed shut" 1 \
  "$(grep -q 'limit:0|readback|terminate|count' <<<"$R_TRACE" && echo 1 || echo 0)"
chk "restore ran"            1 "$(grep -c '^PG_RESTORE_RAN$' <<<"${R_TRACE//|/$'\n'}")"
chk "re-opened"              1 "$(grep -c '^limit:reopened$' <<<"${R_TRACE//|/$'\n'}")"
chk "operator told to boot"  1 "$(grep -c 'app boot' <<<"$R_OUT")"

echo "84. a container that survived the stop stops the restore, door re-opened"
LIVE=1 KILLED=0 FAIL_RESTORE='' run_restore
chk "nothing dropped"    0 "$(grep -c '^PG_RESTORE_RAN$' <<<"${R_TRACE//|/$'\n'}")"
chk "re-opened anyway"   1 "$(grep -c '^limit:reopened$' <<<"${R_TRACE//|/$'\n'}")"
chk "operator told"      1 "$(grep -c 'REFUSING' <<<"$R_OUT")"
chk "and told nothing was dropped" 1 "$(grep -c 'nothing was dropped' <<<"$R_OUT")"

echo "85. a check that itself fails refuses, rather than reading empty as quiet"
LIVE='' KILLED=0 FAIL_RESTORE='' run_restore
chk "nothing dropped"  0 "$(grep -c '^PG_RESTORE_RAN$' <<<"${R_TRACE//|/$'\n'}")"
chk "re-opened anyway" 1 "$(grep -c '^limit:reopened$' <<<"${R_TRACE//|/$'\n'}")"
chk "operator told"    1 "$(grep -c 'REFUSING' <<<"$R_OUT")"

echo "86. a FAILED restore leaves the door shut, so nothing writes to the wreckage"
LIVE=0 KILLED=0 FAIL_RESTORE=1 run_restore
chk "restore attempted"  1 "$(grep -c '^PG_RESTORE_RAN$' <<<"${R_TRACE//|/$'\n'}")"
chk "NOT re-opened"      0 "$(grep -c '^limit:reopened$' <<<"${R_TRACE//|/$'\n'}")"
chk "told it may be half-done" 1 "$(grep -c 'RESTORE FAILED' <<<"$R_OUT")"
chk "not told to boot"   0 "$(grep -c 'app boot' <<<"$R_OUT")"
# A door left shut without saying so is the failure this whole page keeps
# hitting from the other side: the operator meets it later as a boot that
# cannot connect. It has to be stated, and the way out has to be printed.
chk "says the database is deliberately shut" 1 \
  "$(grep -c 'LEFT AT .CONNECTION LIMIT 0.' <<<"$R_OUT")"
chk "says the retry needs no extra step"     1 \
  "$(grep -c 'superuser and is exempt' <<<"$R_OUT")"
chk "prints the command that lifts it"       1 \
  "$(grep -c 'CONNECTION LIMIT -1' <<<"$R_OUT")"

echo "86a. an ALTER that did not take is caught by reading the limit back"
# The gate's own first step was ungated. These blocks are pasted into an
# interactive shell with no `set -e`, so a failed ALTER scrolls past; if nothing
# is attached at that instant the count reads 0 and the restore starts against a
# database that was never shut. Measured on postgres:17 with the ALTER made to
# fail: shut exit=1, live=0, datconnlimit still -1, restore proceeds.
LIVE=0 KILLED=0 FAIL_RESTORE='' FAIL_SHUT=1 run_restore
chk "the limit was read back"  1 "$(grep -c '^readback$' <<<"${R_TRACE//|/$'\n'}")"
chk "nothing dropped"          0 "$(grep -c '^PG_RESTORE_RAN$' <<<"${R_TRACE//|/$'\n'}")"
# It must not even reach the terminate: killing sessions on a database it failed
# to close is a disruption bought for nothing.
chk "no sessions terminated"   0 "$(grep -c '^terminate$' <<<"${R_TRACE//|/$'\n'}")"
# And it must not "re-open" a door it never shut — that would lift a limit the
# operator may have set themselves.
chk "not re-opened either"     0 "$(grep -c '^limit:reopened$' <<<"${R_TRACE//|/$'\n'}")"
chk "operator told"            1 "$(grep -c 'could not shut collavre_production' <<<"$R_OUT")"
chk "and told nothing was dropped" 1 "$(grep -c 'nothing was dropped' <<<"$R_OUT")"
unset FAIL_SHUT

echo "86b. a superuser DB_USER is refused, because the door would not hold it"
# CONNECTION LIMIT is exempt for superusers — that exemption is what lets
# pg_restore in, and it is role-wide, so it lets the app in too whenever the
# app's own role is one. `DB_USER=postgres` on a first run is legal, so this is
# a host the script produces. Measured on postgres:17 with datconnlimit at 0:
#
#   collavre_user (rolsuper f) -> FATAL: too many connections for database ...
#   postgres      (rolsuper t) -> connected, and wrote a row
#
# The refusal has to come before the ALTER, not after: a run that cannot gate
# must leave the connection limit exactly as it found it.
APP_ROLE=postgres APP_SUPER=t LIVE=0 KILLED=0 FAIL_RESTORE='' run_restore
chk "nothing dropped"        0 "$(grep -c '^PG_RESTORE_RAN$' <<<"${R_TRACE//|/$'\n'}")"
chk "the door was never shut" 0 "$(grep -c '^limit:0$' <<<"${R_TRACE//|/$'\n'}")"
chk "nor re-opened"          0 "$(grep -c '^limit:reopened$' <<<"${R_TRACE//|/$'\n'}")"
chk "no sessions terminated" 0 "$(grep -c '^terminate$' <<<"${R_TRACE//|/$'\n'}")"
chk "operator told"          1 "$(grep -c 'cannot shut this database to the app' <<<"$R_OUT")"
# Refusing without naming the one check that does discriminate leaves the
# operator with a blocked restore and no way forward — the failure this page
# hit once already with the superuser rotation guard.
chk "and given the check that does work" 1 "$(grep -c 'app details' <<<"$R_OUT")"

echo "86c. an unanswerable rolsuper refuses too, rather than reading as 'no'"
# `!= f`, not `= t`. Each of these comes back empty, and each is a host where
# the gate cannot be shown to hold.
for shape in "no state file:::" "no such role:ghost::" "cluster unreachable:collavre_user::"; do
  IFS=: read -r what role _ _ <<<"$shape"
  if [ -n "$role" ]; then APP_ROLE="$role"; else unset APP_ROLE; fi
  APP_SUPER='' LIVE=0 KILLED=0 FAIL_RESTORE='' run_restore
  chk "refused: $what" 1 "$(grep -c 'cannot shut this database to the app' <<<"$R_OUT")"
  chk "  nothing dropped: $what" 0 "$(grep -c '^PG_RESTORE_RAN$' <<<"${R_TRACE//|/$'\n'}")"
done
# APP_SUPER as well as APP_ROLE: an assignment placed before a *function* call
# persists in the calling shell in bash, so `APP_SUPER=''` above outlives the
# loop. run_restore reads it with ${APP_SUPER-f}, which cannot restore a default
# for a variable that is set-but-empty — so every later run_restore would refuse
# at the role check and each case after this one would pass for the wrong reason.
unset APP_ROLE APP_SUPER

echo "86d. a re-open that failed is not reported as 'restored, boot the app'"
# The restore worked and the door did not come back up. Nothing in
# $restore_status can see that: the re-open is a separate connection to the
# cluster and fails on its own terms. Unchecked, the block prints the boot
# instruction over a database still at CONNECTION LIMIT 0, and the operator
# meets it as "too many connections" at boot — the misdirected error the whole
# block is built to avoid, produced by the step meant to undo it.
LIVE=0 KILLED=0 FAIL_RESTORE='' FAIL_REOPEN=1 run_restore
chk "the restore did run"        1 "$(grep -c '^PG_RESTORE_RAN$' <<<"${R_TRACE//|/$'\n'}")"
chk "the re-open was attempted"  1 "$(grep -c '^limit:reopened$' <<<"${R_TRACE//|/$'\n'}")"
chk "NOT told to boot"           0 "$(grep -c 'app boot' <<<"$R_OUT")"
chk "told the door is still shut" 1 "$(grep -c 'RE-OPEN FAILED' <<<"$R_OUT")"
# And told which half is intact, because the two failures want opposite
# responses: a half-loaded database wants the restore re-run, a shut one does
# not — re-running --clean would drop a good restore to fix a connection limit.
chk "and that the data is not the problem" 1 \
  "$(grep -c 'not what failed' <<<"$R_OUT")"
chk "prints the command that lifts it"     1 \
  "$(grep -c 'CONNECTION LIMIT -1' <<<"$R_OUT")"
# The half-replaced-database message must NOT appear: it tells the operator to
# re-run the restore, which is the one thing that would turn this into data loss.
chk "does not send them back through pg_restore" 0 \
  "$(grep -c 'RESTORE FAILED' <<<"$R_OUT")"
unset FAIL_REOPEN

echo "86e. a failing re-open on the refusal path is reported too"
# restore_status=2 shut the door and dropped nothing. The door still has to come
# back up, and a re-open that failed there leaves a database the app cannot
# reach with no restore in the story at all to explain it.
LIVE=1 KILLED=0 FAIL_RESTORE='' FAIL_REOPEN=1 run_restore
chk "nothing dropped"             0 "$(grep -c '^PG_RESTORE_RAN$' <<<"${R_TRACE//|/$'\n'}")"
chk "told the door is still shut" 1 "$(grep -c 'RE-OPEN FAILED' <<<"$R_OUT")"
unset FAIL_REOPEN

echo "86f. a database name that needs quoting is shut, restored and re-opened"
# `collavre-prod` is a legal DB_NAME: the launch script creates the database
# through format('%I') and URL-encodes it into DATABASE_URL, so a host can be
# running on one. Unquoted here PostgreSQL reads the hyphen as subtraction, the
# read-back then answers -1, and this block refuses with restore_status=3 — a
# host whose backups cannot be restored by the runbook that wrote them.
APP_DB='collavre-prod' LIVE=0 KILLED=0 FAIL_RESTORE='' run_restore
chk "the door was shut"      1 "$(grep -cx 'limit:0' <<<"${R_TRACE//|/$'\n'}")"
chk "and confirmed shut"     0 "$(grep -c 'REFUSING' <<<"$R_OUT")"
chk "restore ran"            1 "$(grep -cx 'PG_RESTORE_RAN' <<<"${R_TRACE//|/$'\n'}")"
chk "re-opened"              1 "$(grep -cx 'limit:reopened' <<<"${R_TRACE//|/$'\n'}")"
chk "operator told to boot"  1 "$(grep -c 'app boot' <<<"$R_OUT")"

echo "86g. and the recovery it prints for such a name is runnable as printed"
# The recovery is pasted, so the identifier's quotes have to survive the shell
# that pastes it. Printed inside double quotes they would be eaten and the
# command would fail exactly where the operator has no other route left.
APP_DB='collavre-prod' LIVE=0 KILLED=0 FAIL_RESTORE='' FAIL_REOPEN=1 run_restore
chk "told the door is still shut" 1 "$(grep -c 'RE-OPEN FAILED' <<<"$R_OUT")"
chk "the printed ALTER quotes the name" 1 \
  "$(grep -cF "'ALTER DATABASE \"collavre-prod\" CONNECTION LIMIT -1'" <<<"$R_OUT")"
# The same trap recorded at 86c, one variable over: `APP_DB=x run_restore` is a
# prefix assignment on a *function*, so it persists in the calling shell and
# every later case runs against `collavre-prod` instead of the default. It was
# invisible until a case after these two needed the default name back.
unset FAIL_REOPEN APP_DB

echo "86h. a connection limit the operator set is put back, not replaced by -1"
# -1 is only the default. A database deliberately capped has that cap in
# datconnlimit and nowhere else, so re-opening to the literal -1 does not
# restore the database to what it was — it lifts the cap, on every successful
# restore, and the operator finds out when the cap stops holding.
PRIOR_LIMIT=50 LIVE=0 KILLED=0 FAIL_RESTORE='' run_restore
chk "restore ran"                 1 "$(grep -cx 'PG_RESTORE_RAN' <<<"${R_TRACE//|/$'\n'}")"
chk "re-opened"                   1 "$(grep -cx 'limit:reopened' <<<"${R_TRACE//|/$'\n'}")"
chk "left at the operator's cap"  50 "$R_LIMIT"
chk "operator told to boot"       1 "$(grep -c 'app boot' <<<"$R_OUT")"
chk "no note about a lost value"  0 "$(grep -c 'NOTE:' <<<"$R_OUT")"
unset PRIOR_LIMIT

echo "86i. a prior limit that could not be read re-opens to -1 and says so"
# The one case the fix cannot honour: the read failed while the ALTER still
# took. Leaving the door shut for want of a number would produce exactly the
# misdirected "too many connections" the re-open exists to avoid, so -1 is the
# answer — but the operator is the only one who knows what the cap was, so it
# is said rather than assumed.
PRIOR_LIMIT=50 FAIL_PRIOR_READ=1 LIVE=0 KILLED=0 FAIL_RESTORE='' run_restore
chk "restore ran"                 1 "$(grep -cx 'PG_RESTORE_RAN' <<<"${R_TRACE//|/$'\n'}")"
chk "re-opened to the default"    -1 "$R_LIMIT"
chk "and did not stay silent"     1 "$(grep -c 'could not read' <<<"$R_OUT")"
chk "operator told to boot"       1 "$(grep -c 'app boot' <<<"$R_OUT")"
unset PRIOR_LIMIT FAIL_PRIOR_READ

echo "86j. a database the operator had already shut is not advertised as bootable"
# The consequence of putting the limit back faithfully: if it was already 0, the
# re-open restores a closed door. That is the operator's configuration rather
# than a step this block forgot, but "boot the app" would still send them into
# "too many connections" — the error this whole block is arranged to avoid.
PRIOR_LIMIT=0 LIVE=0 KILLED=0 FAIL_RESTORE='' run_restore
chk "restore ran"                  1 "$(grep -cx 'PG_RESTORE_RAN' <<<"${R_TRACE//|/$'\n'}")"
chk "left as the operator had it"  0 "$R_LIMIT"
chk "NOT told to boot"             0 "$(grep -c 'app boot' <<<"$R_OUT")"
# Not "the limit predates this block" any more, and the change is the point. The
# block used to assert that flatly; it cannot, since a failed attempt leaves 0
# behind and a retry from a fresh shell reads that 0 as the previous limit. So
# the two halves are asserted separately: where the value came from, and that
# the one reading which would make it this block's own leftover is named rather
# than argued away.
chk "told where the 0 came from"   1 \
  "$(grep -c 'carried when this block read it' <<<"$R_OUT")"
chk "and that a retry can be its source" 1 \
  "$(grep -c "previous attempt failed" <<<"$R_OUT")"
chk "and how to lift it"           1 \
  "$(grep -cF "'ALTER DATABASE \"collavre_production\" CONNECTION LIMIT -1'" <<<"$R_OUT")"
# Not a failure report: nothing failed, and RESTORE FAILED here would send the
# operator to repair a restore that worked.
chk "not reported as a failure"    0 "$(grep -c 'FAILED' <<<"$R_OUT")"
unset PRIOR_LIMIT

echo "86k. the note is not printed on a path that never shut the door"
# restore_status=3 refuses before the ALTER, so the previous limit is still in
# force and could-not-be-read changes nothing. A warning here would be a warning
# about nothing, on the one path where the operator is already reading a refusal.
APP_DB='' FAIL_PRIOR_READ=1 LIVE=0 KILLED=0 FAIL_RESTORE='' run_restore
chk "refused"                    1 "$(grep -c 'REFUSING' <<<"$R_OUT")"
chk "nothing dropped"            0 "$(grep -cx 'PG_RESTORE_RAN' <<<"${R_TRACE//|/$'\n'}")"
chk "not re-opened"              0 "$(grep -cx 'limit:reopened' <<<"${R_TRACE//|/$'\n'}")"
chk "and no note about a limit"  0 "$(grep -c 'NOTE:' <<<"$R_OUT")"
unset FAIL_PRIOR_READ APP_DB

echo "86l. an ALTER that took but could not be confirmed still gets put back"
# The read-back is a second connection and fails on its own terms — PostgreSQL
# restarted between the two statements, the socket dropped. $shut is then empty,
# which is indistinguishable from the ALTER having failed, and the block took
# the refusing branch and stopped: status 3, "nothing was changed", no re-open.
# But the door really is shut, so what the operator meets next is the app
# refused at boot with "too many connections" — from the block that told them it
# had touched nothing. The ALTER's own exit status is the only thing that can
# tell those two apart, and it is now kept.
PRIOR_LIMIT=25 FAIL_READBACK=1 LIVE=0 KILLED=0 FAIL_RESTORE='' run_restore
chk "refused"                    1 "$(grep -c 'REFUSING' <<<"$R_OUT")"
chk "nothing dropped"            0 "$(grep -cx 'PG_RESTORE_RAN' <<<"${R_TRACE//|/$'\n'}")"
# The assertion the finding is about: what the database is left at, not which
# statements ran. 0 here is an app that cannot start.
chk "left at the operator's cap" 25 "$R_LIMIT"
chk "re-opened"                  1 "$(grep -cx 'limit:reopened' <<<"${R_TRACE//|/$'\n'}")"
# And the refusal must not claim the ALTER failed — that is the one reading it
# has no evidence for, and the one that sends the operator looking at the wrong
# thing while the app stays locked out.
chk "does not blame the ALTER"   0 "$(grep -c 'did not take' <<<"$R_OUT")"
chk "says it cannot tell"        1 "$(grep -c 'reported success' <<<"$R_OUT")"
unset PRIOR_LIMIT FAIL_READBACK

echo "86m. a prior limit that could not be read is still put back on that path"
# Both reads failed: the block has no value to restore and the door may be shut.
# -1 is the lesser wrong here for the same reason it is on the ordinary path —
# leaving it shut for want of a number produces exactly the misdirected "too
# many connections" the re-open exists to avoid — but it must be said out loud,
# and 86k's silence is scoped to the paths that never shut anything, not to
# status 3 as a whole.
FAIL_PRIOR_READ=1 FAIL_READBACK=1 LIVE=0 KILLED=0 FAIL_RESTORE='' run_restore
chk "re-opened to the default"  -1 "$R_LIMIT"
chk "and the operator is told"   1 "$(grep -c 'NOTE: could not read' <<<"$R_OUT")"
unset FAIL_PRIOR_READ FAIL_READBACK

echo "86n. the ALTER failing is still not a reason to touch the limit"
# The negative half of 86l, and the reason this is gated on the ALTER's status
# rather than on "status 3 might have shut it": here the statement did not run,
# the limit is the operator's, and re-opening would be the block changing
# something on the path where it refused to change anything.
PRIOR_LIMIT=25 FAIL_SHUT=1 LIVE=0 KILLED=0 FAIL_RESTORE='' run_restore
chk "not re-opened"              0 "$(grep -cx 'limit:reopened' <<<"${R_TRACE//|/$'\n'}")"
chk "the cap is untouched"       25 "$R_LIMIT"
chk "and the ALTER is blamed"    1 "$(grep -c 'did not take' <<<"$R_OUT")"
unset PRIOR_LIMIT FAIL_SHUT

echo "86o. the retry the failure path invites keeps the cap it printed"
# The instruction under test is the block's own: "Re-running in THIS shell keeps
# that value". It is honoured by ${prior_limit:-...} whenever the prior read
# answered, which is this row.
PRIOR_LIMIT=50 FAIL_RESTORE=1 RERUN=1 LIVE=0 KILLED=0 run_restore
chk "first pass leaves it shut"     1 "$(grep -c 'RESTORE FAILED' <<<"$R_OUT")"
chk "and prints the cap to carry"   1 "$(grep -cF 'prior_limit=50' <<<"$R_OUT")"
chk "the retry restores the cap"    50 "$R_LIMIT"
chk "and reports a plain success"   1 "$(grep -c 'app boot' <<<"$R_OUT")"
unset PRIOR_LIMIT FAIL_RESTORE RERUN

echo "86p. and keeps it when the prior read is the thing that failed"
# `:-` treats an empty value as unset, so a prior read that failed while the
# ALTER still took would be re-read on the retry — off a database this block has
# since shut, which answers 0. The retry then "restores" 0 and reports it as the
# limit the database carried, on the same paste the message above promised would
# keep -1. Measured against the revision without the pin: this row ends at 0 and
# the operator is told the cap is their own.
PRIOR_LIMIT=50 FAIL_RESTORE=1 FAIL_PRIOR_READ=1 RERUN=1 LIVE=0 KILLED=0 run_restore
chk "the value it promised"          1 "$(grep -cF 'prior_limit=-1' <<<"$R_OUT")"
chk "is the value the retry uses"    -1 "$R_LIMIT"
chk "not shut under a success"       0 "$(grep -c "back at 'CONNECTION LIMIT 0'" <<<"$R_OUT")"
unset PRIOR_LIMIT FAIL_RESTORE FAIL_PRIOR_READ RERUN

echo "86q. but a refusal that shut nothing still reads the cluster on the retry"
# The control that shapes the pin, and the reason it is gated on the ALTER's
# status rather than on "the read came back empty". Here the ALTER never took,
# so the cap is still in the cluster and still the operator's — pinning -1 for
# want of a read would lift it on the retry, which is the defect above pointing
# the other way, and worse: it is reachable on a host where nothing went wrong
# with the database at all.
PRIOR_LIMIT=50 FAIL_SHUT=1 FAIL_PRIOR_READ=1 RERUN=1 LIVE=0 KILLED=0 run_restore
chk "first pass refuses"             1 "$(grep -c 'REFUSING' <<<"$R_OUT")"
chk "the retry finds the real cap"   50 "$R_LIMIT"
chk "and needs no note about it"     0 "$(grep -c 'could not read' <<<"$R_OUT")"
unset PRIOR_LIMIT FAIL_SHUT FAIL_PRIOR_READ RERUN

# --- dedupe_authorized_keys -------------------------------------------------
#
# `sort -u -o F F` rewrote authorized_keys in place. A sort stopped after it has
# truncated the output — an OOM kill on the instance this script provisions swap
# for — leaves the file holding a lexical prefix of itself, so the key that goes
# missing is whichever sorts last.
#
# sort is STUBBED here, and that is load-bearing rather than convenient. The
# failure belongs to GNU coreutils, which writes -o in place; BSD sort stages
# and renames already, so on macOS the pre-fix one-liner survives every trigger
# and a test driving the real binary passes against the bug it exists for.
# Measured, same input, `ulimit -f 16`:
#
#   GNU coreutils 9.4 (ubuntu:24.04, what the instance runs)
#     write limit     60001 lines -> 485, current key GONE
#     killed mid-write 60001 lines -> 0,   file EMPTY
#   BSD sort 2.3-Apple (this harness's machine)
#     write limit     201 lines -> 201, byte-identical
#
# So the stub reproduces the GNU shape — truncate the output, then fail — and
# the assertion holds on either platform.

new_keys_env() {
  KEYDIR="$(mktemp -d)"; KEYS="$KEYDIR/authorized_keys"
  : > "$KEYS"
  for i in $(seq 1 200); do
    printf 'ssh-ed25519 %s%03d operator%d@desk\n' \
      "$(head -c 60 /dev/zero | tr '\0' 'A')" "$i" "$i" >> "$KEYS"
  done
  printf '%s\n' "$KEY_CURRENT" >> "$KEYS"
  printf '%s\n' "$KEY_CURRENT" >> "$KEYS"        # a duplicate for it to remove
  LOGGED=""
}
KEY_CURRENT='ssh-ed25519 zzCURRENT current@laptop'   # sorts last, so it is the casualty

echo "87. the ordinary case still drops duplicates"
new_keys_env
before=$(wc -l < "$KEYS")
dedupe_authorized_keys "$KEYS" "$KEY_CURRENT"
chk "one line shorter"     "$(( before - 1 ))" "$(wc -l < "$KEYS" | tr -d ' ')"
chk "the current key kept" 1 "$(grep -cxF "$KEY_CURRENT" "$KEYS")"
chk "silent"               "" "$LOGGED"
chk "no scratch file left" 0 "$(find "$KEYDIR" -name 'authorized_keys.sort.*' | wc -l | tr -d ' ')"

echo "88. a sort that dies part way leaves authorized_keys alone"
new_keys_env
before_l=$(wc -l < "$KEYS" | tr -d ' '); before_b=$(wc -c < "$KEYS" | tr -d ' ')
# GNU sort's -o target is opened and truncated before the run can fail, so a
# partial write leaves a prefix behind. Copied from the measured run above.
# shellcheck disable=SC2329,SC2120  # shadows sort for dedupe_authorized_keys only
sort() {
  local out=""
  while [ $# -gt 0 ]; do
    case "$1" in -o) out="$2"; shift 2 ;; *) shift ;; esac
  done
  [ -n "$out" ] && head -c 200 > "$out"          # truncate, write a prefix...
  return 2                                        # ...then fail, as GNU does
}
dedupe_authorized_keys "$KEYS" "$KEY_CURRENT" >/dev/null 2>&1
unset -f sort
chk "not truncated"  "$before_l" "$(wc -l < "$KEYS" | tr -d ' ')"
chk "byte-identical" "$before_b" "$(wc -c < "$KEYS" | tr -d ' ')"
# Both copies are still there — the file was not rewritten at all, which is the
# point. Deduplication is cosmetic; keeping every key is not.
chk "the current key survives" 2 "$(grep -cxF "$KEY_CURRENT" "$KEYS")"
chk "no scratch file left" 0 "$(find "$KEYDIR" -name 'authorized_keys.sort.*' | wc -l | tr -d ' ')"

echo "89. it stages beside the target, not in TMPDIR"
# Same filesystem, so the swap is one rename and a full or missing /tmp cannot
# reach the file the operator logs in with. Asserted on the path mktemp is asked
# for: GNU mktemp fails on a missing TMPDIR but BSD mktemp falls back, so a
# TMPDIR-based check would pass vacuously on the machine this harness runs on.
new_keys_env
tmpl_log="$KEYDIR/template"
# shellcheck disable=SC2329  # shadows mktemp for dedupe_authorized_keys only
mktemp() { printf '%s\n' "$1" >> "$tmpl_log"; command mktemp "$@"; }
dedupe_authorized_keys "$KEYS" "$KEY_CURRENT"
unset -f mktemp
chk "template is a sibling of authorized_keys" 1 \
  "$(grep -c "^$KEYS\.sort\." "$tmpl_log")"

# --- install_staged_authorized_keys ------------------------------------------
#
# Staging is only half of it: what is staged still has to arrive. `cat "$tmp" >
# "$auth_keys"` puts the O_TRUNC in the calling shell and the write in a
# separate process, so the live path is empty across a whole process spawn
# rather than across one write(2). Killing that writer at a uniformly random
# point, on a realistic four-key file:
#
#   cat "$tmp" > "$auth_keys"   damaged 7/400, every one of them 0 bytes
#   mv  "$tmp"   "$auth_keys"   damaged 0/400
#
# Both cases below assert the property rather than the spelling, so a later
# rewrite that reintroduces a copy fails them however it is written.

ino() { stat -c %i "$1" 2>/dev/null || stat -f %i "$1"; }

echo "90. the live path is replaced, never rewritten in place"
new_keys_env
before_ino=$(ino "$KEYS")
tmp="$(mktemp "$KEYS.sort.XXXXXX")"
printf '%s\n' "$KEY_CURRENT" > "$tmp"
staged_ino=$(ino "$tmp")
install_staged_authorized_keys "$tmp" "$KEYS"
# A copy leaves the target's inode alone; a rename carries the staged file's in.
# That is the difference between "the file was emptied and refilled" and "the
# file was swapped", and it is what decides whether an interrupted run can be
# seen by sshd holding a partial file.
chk "the staged inode is now the live one" "$staged_ino" "$(ino "$KEYS")"
chk "and it is not the old one"            1 \
  "$([ "$before_ino" != "$(ino "$KEYS")" ] && echo 1 || echo 0)"
chk "contents arrived whole"               1 "$(grep -cxF "$KEY_CURRENT" "$KEYS")"
chk "no scratch file left"                 0 \
  "$(find "$KEYDIR" -name 'authorized_keys.sort.*' | wc -l | tr -d ' ')"

echo "91. ownership and mode are set before the swap, not after"
# The obvious form of the fix has a lockout of its own. mktemp creates 0600
# root-owned, and sshd with StrictModes refuses an authorized_keys it cannot
# read as the user — measured against a real sshd:
#
#   owner=collavre mode=600 -> OK    owner=root mode=600 -> Authentication
#   owner=root     mode=644 -> OK    refused: bad ownership or modes
#
# So a crash between a bare `mv` and the caller's chown leaves the host refusing
# the key the run just installed. Asserted as an ordering, because the final
# state is identical either way and only the window differs.
new_keys_env
order="$KEYDIR/order"; : > "$order"
# shellcheck disable=SC2329  # shadow chown/chmod/mv for this case only
chown() { echo "chown $*" >> "$order"; }
# shellcheck disable=SC2329
chmod() { echo "chmod $*" >> "$order"; command chmod "$@"; }
# shellcheck disable=SC2329
mv() { echo "mv $*" >> "$order"; command mv "$@"; }
tmp="$(mktemp "$KEYS.sort.XXXXXX")"
printf '%s\n' "$KEY_CURRENT" > "$tmp"
APP_SSH_USER=collavre APP_SSH_GROUP=collavre install_staged_authorized_keys "$tmp" "$KEYS"
# Restored rather than unset: the suite-wide stub is what lets every later case
# run the install path unprivileged, and `unset -f` here would drop it for the
# rest of the file instead of just ending this case's recording.
unset -f chmod mv; chown() { [ "$CHOWN_FAILS" = 0 ]; }
chk "chown ran on the staging file" 1 "$(grep -c "^chown collavre:collavre $KEYS\.sort\." "$order")"
chk "chmod ran on the staging file" 1 "$(grep -c "^chmod 0600 $KEYS\.sort\." "$order")"
mv_at=$(grep -n '^mv ' "$order" | cut -d: -f1); chmod_at=$(grep -n '^chmod ' "$order" | cut -d: -f1)
chk "both before the rename"        1 \
  "$([ -n "$mv_at" ] && [ -n "$chmod_at" ] && [ "$mv_at" -gt "$chmod_at" ] && echo 1 || echo 0)"
chk "the live file ends 0600"       600 "$(stat -c %a "$KEYS" 2>/dev/null || stat -f %Lp "$KEYS")"

# Present only in the staged file, so "did the staged contents reach the live
# path" is answerable by looking at the live path alone.
KEY_STAGED_ONLY='ssh-ed25519 zzSTAGED staged@laptop'

echo "91a. a staging file that could not be given to the user is NOT installed"
# `chown ... || true` put the root-owned 0600 file at the live path, and the
# caller's own `chown "$APP_SSH_USER:$APP_SSH_GROUP" "$AUTH_KEYS"` a few lines
# later is not a recovery from that: it is the same command on the same names,
# so it fails for whatever reason the first one did and `set -e` ends the run
# with the unreadable file already live. sshd with StrictModes then refuses the
# key the run just installed, and on APP_SSH_USER=ubuntu that file is the only
# way into the instance.
#
# So the assertion is about the LIVE file, not about the return value: what
# makes declining safe is that what was already there still works.
new_keys_env
printf '%s\n' "$KEY_CURRENT" > "$KEYS"
live_before="$(cat "$KEYS")"
tmp="$(mktemp "$KEYS.sort.XXXXXX")"
printf '%s\n' "$KEY_CURRENT" "$KEY_STAGED_ONLY" > "$tmp"
LOGGED=""
CHOWN_FAILS=1
APP_SSH_USER=collavre APP_SSH_GROUP=collavre \
  install_staged_authorized_keys "$tmp" "$KEYS" && st=0 || st=$?
CHOWN_FAILS=0
chk "it reports failure"            1 "$st"
chk "the live file is untouched"    "$live_before" "$(cat "$KEYS")"
chk "and still holds a usable key"  1 "$(grep -cxF "$KEY_CURRENT" "$KEYS")"
chk "the staging file is cleaned up" 0 "$([ -e "$tmp" ] && echo 1 || echo 0)"
case "$LOGGED" in
  *"NOT installed"*) echo "  ok   says the file was not installed" ;;
  *) echo "  FAIL silent about declining: $LOGGED"; fail=1 ;;
esac
# The negative control. Under the previous form the same failure installed the
# file anyway, which is the finding: the live path takes the staged contents
# from a chown that did not happen.
install_prev() {   # the previous revision of install_staged_authorized_keys
  local tmp="$1" auth_keys="$2"
  [ -z "${APP_SSH_USER:-}" ] || chown "$APP_SSH_USER:${APP_SSH_GROUP:-$APP_SSH_USER}" "$tmp" 2>/dev/null || true
  command chmod 0600 "$tmp"
  command mv -f "$tmp" "$auth_keys"
}
printf '%s\n' "$KEY_CURRENT" > "$KEYS"
tmp="$(mktemp "$KEYS.sort.XXXXXX")"
printf '%s\n' "$KEY_CURRENT" "$KEY_STAGED_ONLY" > "$tmp"
CHOWN_FAILS=1
APP_SSH_USER=collavre APP_SSH_GROUP=collavre install_prev "$tmp" "$KEYS"
CHOWN_FAILS=0
chk "the previous form installed it regardless" 1 "$(grep -cxF "$KEY_STAGED_ONLY" "$KEYS")"
# install_prev only. `unset -f log` here would expose /usr/bin/log on macOS,
# which exits 64 on the next call and fails a case several hundred lines away
# for a reason that has nothing to do with what it tests.
unset -f install_prev

# --- postgresql_conf_includes_confd -----------------------------------------
#
# The predicate was `grep -q "include_dir = 'conf.d'"`, which a COMMENTED
# directive satisfies. Debian and Ubuntu ship the directive active, so a fresh
# install is fine and the by-hand converge path on a host where an operator
# disabled it is not: measured on ubuntu:24.04, the run wrote
# conf.d/10-collavre.conf, restarted the cluster cleanly and reported success,
# while PostgreSQL never read the file —
#
#   listen_addresses in force : localhost
#   listening on 172.17.0.1   : NO   (bound: 127.0.0.1:5432, [::1]:5432)
#   DATABASE_URL handed out   : ...@172.17.0.1:5432/collavre_production
#
# so the containers are pointed at an address nothing is listening on, several
# steps after the step that caused it.

echo "92. an active include_dir is honoured, so nothing is appended"
for active in \
  "include_dir = 'conf.d'" \
  "include_dir='conf.d'" \
  "  include_dir = 'conf.d'  # stock Debian" \
  "include_dir = '/etc/postgresql/16/main/conf.d'" \
  "include_dir = conf.d"
do
  f=$(mktemp); printf "port = 5432\n%s\nmax_connections = 100\n" "$active" > "$f"
  postgresql_conf_includes_confd "$f"
  chk "skipped: $active" 0 "$?"
  rm -f "$f"
done

echo "93. a commented-out include_dir does not count as configured"
# The one that shipped. Each of these leaves conf.d unread by PostgreSQL.
for off in \
  "#include_dir = 'conf.d'" \
  "#  include_dir = 'conf.d'" \
  "   #include_dir = 'conf.d'   # turned this off, using the main file" \
  "#include_dir = '...'" \
  "include_dir = 'other.d'" \
  "include_dir = 'myconf.d'" \
  "include_if_exists = 'conf.d'"
do
  f=$(mktemp); printf "port = 5432\n%s\nmax_connections = 100\n" "$off" > "$f"
  postgresql_conf_includes_confd "$f"
  chk "install needed: $off" 1 "$?"
  rm -f "$f"
done

echo "94. at the call site, a disabled directive gets the managed block"
# The predicate on its own could be right while the caller still skipped, so
# this drives the pair and then reads what PostgreSQL would.
f=$(mktemp)
printf "port = 5432\n#include_dir = 'conf.d'\n" > "$f"
postgresql_conf_includes_confd "$f" || ensure_block "$f" include "include_dir = 'conf.d'"
chk "conf.d is now actually included" 1 \
  "$(sed 's/#.*//' "$f" | grep -cE "^[[:space:]]*include_dir[[:space:]]*=[[:space:]]*'conf\.d'")"
chk "the operator's own line is untouched" 1 "$(grep -c "^#include_dir = 'conf.d'$" "$f")"
# Re-running must not stack a second block on a host converged by this change.
postgresql_conf_includes_confd "$f" || ensure_block "$f" include "include_dir = 'conf.d'"
chk "and a re-run appends nothing" 1 "$(grep -c '# BEGIN collavre:include' "$f")"
rm -f "$f"

# --- refuse_db_name_change --------------------------------------------------
#
# DB_NAME was the one identifier a re-run could change with no trace: the SQL is
# create-if-missing, nothing renames the old database, and nothing recorded
# which one a previous run chose. Measured on postgres:17 against a host holding
# 5,000 rows, re-running with a mistyped name:
#
#   run reports success
#   tables in the new one the URL and backup will name : 0
#   rows in the real one, now referenced by nothing    : 5000
#
# The data is not destroyed; it is orphaned, and the nightly pg_dump moves to
# the empty database. Both halves are silent.

# Its own stub rather than the shared one above: this guard asks pg_database a
# count(*), which the shared stub answers with the ROLE_EXISTS probe.
# shellcheck disable=SC2329  # called by refuse_db_name_change
psql_as_postgres() {
  case "$2" in
    *pg_database*datistemplate*) printf '%s\n' "$DB_LIST" ;;
    *pg_database*)               printf '%s\n' "$DB_EXISTS" ;;
  esac
}
DB_EXISTS=1 DB_LIST="collavre_production"

echo "95. a changed DB_NAME is refused before anything is created"
dn=$(mktemp -d)
printf 'collavre_production\n' > "$dn/db_name"
printf 'collavre_user\n'       > "$dn/db_user"
out="$( (refuse_db_name_change collavre_prod "$dn") 2>&1 )"
chk "exits non-zero" 1 "$?"
chk "the marker still names the real database" "collavre_production" "$(cat "$dn/db_name")"
case "$out" in
  *"provisioned with DB_NAME='collavre_production'"*"created empty"*"Nothing has been changed"*)
    echo "  ok   names the state, the consequence and the way out" ;;
  *) echo "  FAIL unhelpful: $out"; fail=1 ;;
esac
# The shapes that must still go through.
refuse_db_name_change collavre_production "$dn"
chk "an unchanged DB_NAME proceeds" 0 "$?"
dn2=$(mktemp -d)
refuse_db_name_change collavre_production "$dn2"
chk "a genuine first run proceeds"  0 "$?"
chk "and it is a first run precisely because nothing was provisioned here" \
  0 "$(find "$dn2" -mindepth 1 | wc -l | tr -d ' ')"

echo "96. an older host with no db_name record is judged by the cluster"
# The migration case. Adopting blindly would let exactly the reported change
# through on every host provisioned before this marker existed.
dn3=$(mktemp -d); printf 'collavre_user\n' > "$dn3/db_user"
DB_EXISTS=1
refuse_db_name_change collavre_production "$dn3"
chk "the database it names exists, so adopt it" 0 "$?"
DB_EXISTS=0 DB_LIST="collavre_production"
out="$( (refuse_db_name_change collavre_prod "$dn3") 2>&1 )"
chk "it does not exist, so refuse"  1 "$?"
case "$out" in
  *"provisioned before"*"does not exist"*"collavre_production"*)
    echo "  ok   refuses and lists what is actually there" ;;
  *) echo "  FAIL unhelpful: $out"; fail=1 ;;
esac
# An empty cluster listing must not read as a missing variable.
DB_EXISTS=0 DB_LIST=""
out="$( (refuse_db_name_change collavre_prod "$dn3") 2>&1 )"
case "$out" in
  *"Databases present: (none)"*) echo "  ok   an empty listing says so" ;;
  *) echo "  FAIL bare or confusing listing: $out"; fail=1 ;;
esac

echo "97. an empty marker is not treated as a previous name"
# A truncated write would otherwise refuse every future run against ''.
dn4=$(mktemp -d); : > "$dn4/db_name"; printf 'collavre_user\n' > "$dn4/db_user"
DB_EXISTS=1
refuse_db_name_change collavre_production "$dn4"
chk "proceeds rather than refusing against an empty name" 0 "$?"

echo "97a. but an empty marker does not answer for the record it lost"
# 97 above is only half the question, and the half that passes either way: the
# database it names exists, so there is nothing to protect and every revision
# proceeds. The other half is the one that matters. An empty db_name is not
# "nothing was recorded here" — it is "a name was recorded and this run cannot
# read it", which is the same state case 96 refuses on a host too old to have
# written one at all. The earlier form returned 0 from inside the `-f` branch,
# so an empty file skipped the comparison AND the cluster fallback beneath it,
# and the guard passed a changed DB_NAME on a host it was installed to defend.
#
# That is reachable from this PR's own write: `> "$STATE_DIR/db_name"`
# truncates before it writes, so a run interrupted between the two leaves
# exactly this file.
dn5=$(mktemp -d); : > "$dn5/db_name"; printf 'collavre_user\n' > "$dn5/db_user"
DB_EXISTS=0 DB_LIST="collavre_production"
out="$( (refuse_db_name_change collavre_typo "$dn5") 2>&1 )"
chk "an unreadable marker is refused, not adopted" 1 "$?"
case "$out" in
  *"provisioned before"*"does not exist"*"collavre_production"*)
    echo "  ok   and it lists the database the data is actually in" ;;
  *) echo "  FAIL passed or was unhelpful: $out"; fail=1 ;;
esac

unset -f psql_as_postgres
rm -rf "$dn" "$dn2" "$dn3" "$dn4" "$dn5"

# --- adopt_legacy_ssh_key_marker --------------------------------------------
#
# An earlier revision kept ONE record of the managed SSH key per host. Re-filing
# it under whichever account APP_SSH_USER names today is not a migration, it is
# a guess — and on a host that rotated accounts under that revision the guess is
# wrong in the direction that grants root. Driven through the reported sequence
# with the real functions:
#
#   world that revision left: marker=key-B, collavre holds key-A, deploybot key-B
#   run names collavre/key-C -> B filed as collavre's predecessor
#   withdrawal looks for B in collavre's file : NOT FOUND, nothing withdrawn
#   collavre authorized_keys : key-A, key-C      key-A still authorized: 1
#   deploybot's marker       : consumed, so key-B is unwithdrawable too
#
# Both halves are silent, and the run then re-arms collavre with `usermod -aG
# sudo` and the docker group, so key-A is root again. The functions take a
# passwd table so the shapes can be built without accounts on this machine.
ssh_world() {
  W=$(mktemp -d)
  mkdir -p "$W/state" "$W/home/collavre/.ssh" "$W/home/deploybot/.ssh"
  printf 'collavre:x:1001:1001::%s/home/collavre:/bin/bash\n' "$W" > "$W/passwd"
  printf 'deploybot:x:1002:1002::%s/home/deploybot:/bin/bash\n' "$W" >> "$W/passwd"
  KA='ssh-ed25519 AAAAKEY-A operator-A'
  KB='ssh-ed25519 AAAAKEY-B operator-B'
}

echo "98. a marker that names another account's key does not become this one's"
ssh_world
printf '%s\n' "$KA" > "$W/home/collavre/.ssh/authorized_keys"
printf '%s\n' "$KB" > "$W/home/deploybot/.ssh/authorized_keys"
printf '%s\n' "$KB" > "$W/state/ssh_public_key"
OUT="$( adopt_legacy_ssh_key_marker collavre "$W/state" "$W/passwd" 2>&1 )"
chk "exits non-zero" 1 "$?"
# The refusal has to be a refusal: the sudo grant and the docker group are a few
# lines below the call site, so continuing is what turns a stale key into root.
chk "no predecessor invented for collavre" 0 \
  "$([ -f "$W/state/ssh_public_key.collavre" ] && echo 1 || echo 0)"
chk "and deploybot's record is not consumed" 1 \
  "$([ -f "$W/state/ssh_public_key" ] && echo 1 || echo 0)"
chk "names the other account"    1 "$(grep -c "authorized for 'deploybot'" <<<"$OUT")"
chk "and the way out"            1 "$(grep -c 'ACK_UNATTRIBUTED_SSH_KEYS=1' <<<"$OUT")"
rm -rf "$W"

echo "99. the shapes that must still go through, still do"
# The refusal is only worth having if it is narrow. Each of these is a host the
# adoption exists to serve, and stopping any of them would be worse than the
# escalation: the first one is the ordinary upgrade, and without it the first
# run after the per-account change would withdraw nothing and then advance,
# leaving the key it replaced authorized forever.
ssh_world
printf '%s\n' "$KA" > "$W/home/collavre/.ssh/authorized_keys"
printf '%s\n' "$KA" > "$W/state/ssh_public_key"
adopt_legacy_ssh_key_marker collavre "$W/state" "$W/passwd" >/dev/null 2>&1
chk "the account's own key is adopted" "$KA" "$(cat "$W/state/ssh_public_key.collavre" 2>/dev/null)"
chk "  claimed once, not copied" 0 "$([ -f "$W/state/ssh_public_key" ] && echo 1 || echo 0)"
rm -rf "$W"

ssh_world
: > "$W/home/collavre/.ssh/authorized_keys"
printf '%s\n' "$KB" > "$W/home/deploybot/.ssh/authorized_keys"
printf '%s\n' "$KB" > "$W/state/ssh_public_key"
adopt_legacy_ssh_key_marker collavre "$W/state" "$W/passwd" >/dev/null 2>&1
chk "an account with no keys cannot be hiding one, so it is filed at its owner" 1 \
  "$([ -f "$W/state/ssh_public_key.deploybot" ] && echo 1 || echo 0)"
rm -rf "$W"

ssh_world
printf '%s\n' "$KA" > "$W/home/collavre/.ssh/authorized_keys"
printf 'ssh-ed25519 GONE gone\n' > "$W/state/ssh_public_key"
adopt_legacy_ssh_key_marker collavre "$W/state" "$W/passwd" >/dev/null 2>&1
chk "a key authorized for nobody is dropped, not filed" 0 \
  "$([ -f "$W/state/ssh_public_key.collavre" ] && echo 1 || echo 0)"
chk "  and the stale record does not survive to refuse every later run" 0 \
  "$([ -f "$W/state/ssh_public_key" ] && echo 1 || echo 0)"
rm -rf "$W"

ssh_world
printf '%s\n' "$KA" > "$W/home/collavre/.ssh/authorized_keys"
printf '%s\n' "$KB" > "$W/home/deploybot/.ssh/authorized_keys"
printf '%s\n' "$KB" > "$W/state/ssh_public_key"
ACK_UNATTRIBUTED_SSH_KEYS=1 \
  adopt_legacy_ssh_key_marker collavre "$W/state" "$W/passwd" >/dev/null 2>&1
chk "the acknowledged override proceeds, filing at the owner" 1 \
  "$([ -f "$W/state/ssh_public_key.deploybot" ] && echo 1 || echo 0)"
rm -rf "$W"

ssh_world
adopt_legacy_ssh_key_marker collavre "$W/state" "$W/passwd" >/dev/null 2>&1
chk "a first run with no legacy record is a silent no-op" 0 "$?"
rm -rf "$W"

# The cases above all pass a passwd table, which is the third argument and the
# reason they can run without accounts on this machine. Production does not pass
# it, and that argument selects between two different implementations — so
# without a case that omits it, every one of them exercises a function the host
# never runs. It is the branch the host DOES run that fails: `getent passwd
# <missing>` exits 2, the pipeline into `cut` carries that status under
# `pipefail`, and the caller's plain `home="$(passwd_home ...)"` hands it to
# `set -e`. The run ends at that line, with no message from either branch of the
# function — on the first-run-creates-the-user path the function's own comment
# names as supported.
echo "99a. a missing account is an answer on the production path, not a failure"
ssh_world
getent() { return 2; }   # Ubuntu: nothing on stdout, exit 2
( set -e; passwd_home ghost >/dev/null )
chk "passwd_home does not fail for an account that does not exist" 0 "$?"
out="$( passwd_home ghost )"
chk "  and reports it the same way the awk branch does" "" "$out"
printf '%s\n' "$KB" > "$W/state/ssh_public_key"
( set -e; adopt_legacy_ssh_key_marker collavre "$W/state" >/dev/null 2>&1 )
chk "so the caller survives it under the run's own set -e" 0 "$?"
unset -f getent
rm -rf "$W"

# --- step 6, at the call site -----------------------------------------------
#
# refuse_superuser_db_rotation ran AFTER the new DB_PASSWORD was written to
# $STATE_DIR, so a refusal whose message says "Nothing has been changed" had
# already changed something, and it outlived the run. The recovery that message
# recommends — re-run with the previous DB_USER and no DB_PASSWORD — reads the
# state file back, so it applied the password of the abandoned rotation to the
# role nobody asked to change, and the DATABASE_URL already deployed stopped
# authenticating. Verified over scram auth on postgres:17 rather than by
# reading. Extracted from the script so the ORDER is what is under test.
step6="$(awk '/^log "6\/9/ { f = 1 } f { print } f && /^chmod 0600 "\$STATE_DIR\/db_password"$/ { exit }' "$SRC")"
[ -n "$step6" ] || { echo "  FAIL could not extract step 6 from $SRC"; fail=1; }

echo "100. a refused rotation writes nothing to the state directory"
s6=$(mktemp -d)
printf 'postgres' > "$s6/db_user"          # provisioned with the superuser
printf 'OLD-PASSWORD' > "$s6/db_password"  # the one DATABASE_URL was built from
printf 'collavre_production\n' > "$s6/db_name"
OUT="$(
  STATE_DIR="$s6" DB_USER=collavre_app DB_PASSWORD=NEW-PASSWORD \
  DB_NAME=collavre_production bash -c '
    set -uo pipefail
    '"$(declare -f die refuse_superuser_db_rotation role_owns_app_objects refuse_db_name_change)"'
    # Its own log(), not the harness one: that appends to $LOGGED, which is
    # unbound in here, so under set -u the extracted region would die on its
    # first line and both assertions below would pass for the wrong reason.
    log() { echo "[log] $*"; }
    psql_as_postgres() {
      case "$2" in
        *"count(*) FROM pg_roles"*) echo 1 ;;   # postgres exists
        *rolsuper*)                 echo t ;;   # and is a superuser
        *pg_class*)                 echo 5 ;;   # still owns application objects
        *pg_database*)              echo 1 ;;
      esac
    }
    '"$step6"'
  ' 2>&1
)"
chk "the rotation is refused"  1 "$(grep -c 'which is a superuser' <<<"$OUT")"
# The whole point: the message and the filesystem must agree.
chk "and the message is true"  OLD-PASSWORD "$(cat "$s6/db_password")"
rm -rf "$s6"

echo "101. a re-run that changes both DB_NAME and DB_USER names the right one"
# The two guards are not independent. refuse_superuser_db_rotation counts the
# objects the previous role owns IN $DB_NAME, so when both change it asks that
# of a database that does not exist: psql fails, the count comes back empty, and
# the deliberate "unanswerable reads as unsafe" rule turns it into a refusal
# about object ownership. Measured on postgres:17 with the guards in the other
# order — it dies with "An unknown number of object(s) in 'collavre_prod' are
# still owned by 'postgres' ... Move the objects by hand", and that transfer
# cannot be performed on a database that is not there. Nothing is changed either
# way, so this is about which problem the operator is sent to fix.
s6b=$(mktemp -d)
printf 'postgres' > "$s6b/db_user"
printf 'OLD-PASSWORD' > "$s6b/db_password"
printf 'collavre_production\n' > "$s6b/db_name"
OUT="$(
  STATE_DIR="$s6b" DB_USER=collavre_app DB_PASSWORD=NEW-PASSWORD \
  DB_NAME=collavre_prod bash -c '
    set -uo pipefail
    '"$(declare -f die refuse_superuser_db_rotation role_owns_app_objects refuse_db_name_change)"'
    log() { echo "[log] $*"; }
    psql_as_postgres() {
      case "$2" in
        *"count(*) FROM pg_roles"*) echo 1 ;;
        *rolsuper*)                 echo t ;;
        # The database named by this run does not exist, so the ownership query
        # cannot run at all. Empty stdout is what psql leaves behind, measured.
        *pg_class*)                 return 2 ;;
        *pg_database*)              echo 0 ;;
      esac
    }
    '"$step6"'
  ' 2>&1
)"
chk "the run is refused"                 1 "$(grep -c 'Nothing has been changed' <<<"$OUT")"
chk "and it is the name it complains about" 1 "$(grep -c "provisioned with DB_NAME='collavre_production'" <<<"$OUT")"
chk "not an ownership transfer that cannot be done" 0 "$(grep -c 'Move the objects by hand' <<<"$OUT")"
chk "nor an object count it could not obtain"       0 "$(grep -c 'An unknown number of' <<<"$OUT")"
chk "and nothing was written"       OLD-PASSWORD "$(cat "$s6b/db_password")"
rm -rf "$s6b"

# --- docs/deploy_to_lightsail.md, the DB_NAME rename -------------------------
#
# /var/lib/collavre/db_name is what a later launch-script run trusts to tell a
# deliberate rename from a typo. A rename that failed with a marker that
# advanced anyway is the one combination that makes that run create an empty
# database under the new name and move DATABASE_URL and the backup job onto it
# — the outcome refuse_db_name_change exists to prevent, reached from the
# operator's side instead of the script's. The block is pasted into an
# interactive shell with no `set -e`, so a failed ALTER scrolls past.

rename_recipe="$(extract_recipe 'RENAME TO')"
case "$rename_recipe" in
  *"ALTER DATABASE"*"RENAME TO"*db_name*) : ;;
  *) echo "could not extract the DB_NAME rename recipe from $DOC — has it moved?" >&2
     exit 1 ;;
esac

# FAIL_RENAME makes the ALTER fail the way a surviving session makes it fail.
# FAIL_LOOKUP fails the confirmation itself, which must also not advance the
# marker: "could not be checked" is not "checked and true".
run_rename() {
  local work; work="$(mktemp -d)"
  mkdir -p "$work/bin" "$work/state"
  printf 'collavre_production\n' > "$work/state/db_name"
  printf '%s' "$rename_recipe" > "$work/recipe.sh"

  cat > "$work/bin/sudo" <<'STUB'
#!/usr/bin/env bash
while [ "${1:-}" = -u ] || [ "${1:-}" = postgres ]; do shift; done
exec "$@"
STUB
  # The cluster is modelled as state ($RENAMED), so the confirmation reads what
  # the rename actually did rather than re-reading its exit status — otherwise
  # the check asserts nothing the `&&` did not already assert.
  cat > "$work/bin/psql" <<'STUB'
#!/usr/bin/env bash
sql="${*: -1}"
case "$sql" in
  *"RENAME TO"*)  echo rename >>"$TRACE"
                  [ -z "$FAIL_RENAME" ] || {
                    echo 'ERROR:  database "collavre_production" is being accessed by other users' >&2
                    exit 1; }
                  : > "$RENAMED" ;;
  *pg_database*)  echo lookup >>"$TRACE"
                  [ -z "$FAIL_LOOKUP" ] || exit 1
                  [ ! -f "$RENAMED" ] || echo 1 ;;
esac
STUB
  cat > "$work/bin/tee" <<'STUB'
#!/usr/bin/env bash
echo tee >>"$TRACE"
exec /usr/bin/tee "${1/\/var\/lib\/collavre/$STATE}"
STUB
  chmod +x "$work/bin"/*

  TRACE="$work/trace"; : > "$TRACE"
  export TRACE STATE="$work/state" RENAMED="$work/renamed" \
         FAIL_RENAME="${FAIL_RENAME:-}" FAIL_LOOKUP="${FAIL_LOOKUP:-}"
  REN_OUT="$(cd "$work" && PATH="$work/bin:$PATH" bash ./recipe.sh 2>&1)"
  REN_TRACE="$(paste -sd'|' "$TRACE")"
  REN_MARKER="$(cat "$work/state/db_name")"
  rm -rf "$work"
}

echo "102. a rename that succeeded advances the marker"
FAIL_RENAME='' FAIL_LOOKUP='' run_rename
chk "the new name is recorded" "collavre_prod" "$REN_MARKER"
chk "and it was confirmed against the cluster first" "rename|lookup|tee" "$REN_TRACE"

echo "103. a rename that FAILED leaves the marker naming the real database"
# The negative control: against the two-statement form this fails with
# `expected [collavre_production] got [collavre_prod]`, which is the finding.
FAIL_RENAME=1 FAIL_LOOKUP='' run_rename
chk "the marker still names the data"  "collavre_production" "$REN_MARKER"
chk "and nothing was written to it"    0 "$(grep -c '^tee$' <<<"${REN_TRACE//|/$'\n'}")"

echo "104. a rename that cannot be confirmed does not advance the marker either"
# psql exiting non-zero on the lookup, or a cluster that went away between the
# two statements. `grep -qx 1` on empty output is what makes this fail closed;
# gating on psql's own status would not, since the pipeline's status is grep's.
FAIL_RENAME='' FAIL_LOOKUP=1 run_rename
chk "the marker was not advanced"      "collavre_production" "$REN_MARKER"
chk "nothing was written to it"        0 "$(grep -c '^tee$' <<<"${REN_TRACE//|/$'\n'}")"

echo "105. no recipe on the page hard-codes the deploy user"
# Only APP_SSH_USER is guaranteed to hold the key, the sudo grant and docker
# membership. Spelling it `collavre` sends every recipe to an account that may
# not exist on a host provisioned with the documented override, and the failure
# lands at the first scp — before the operator has any reason to suspect the
# runbook rather than their own setup.
chk "no 'collavre@' anywhere in the runbook" 0 "$(grep -c 'collavre@' "$DOC")"
# And the placeholder has to be the one the harnesses above substitute, or these
# recipes go untested while looking tested.
chk "the SSH recipes use <deploy-user>" 1 \
  "$(grep -cq '<deploy-user>@<instance-ip>' "$DOC" && echo 1 || echo 0)"

echo "106. the recipes name no database role or database of their own"
# The counterpart of 105 for DB_USER and DB_NAME, which are overridable in the
# same way APP_SSH_USER is. A literal role fails the import at SET ROLE and the
# cutover at its first ALTER ROLE; a literal database name is worse in the
# restore, which would shut, terminate and reload the wrong one. Asserted on
# the extracted recipes rather than on the whole page, because the prose around
# them is entitled to name the defaults.
chk "the import names no role of its own"      0 "$(grep -c 'collavre_user' <<<"$move")"
chk "nor a database of its own"                0 "$(grep -c 'collavre_production' <<<"$move")"
chk "the cutover names no role of its own"     0 "$(grep -c 'collavre_user' <<<"$recipe")"
chk "the restore names no database of its own" 0 "$(grep -c 'collavre_production' <<<"$restore")"
# And the placeholders are the ones the harnesses above substitute — an
# unsubstituted `<db-user>` is a redirection, so these recipes would go untested
# while looking tested.
chk "and they use <db-user>/<db-name>"         1 \
  "$(grep -q '<db-user>' <<<"$move$recipe" && echo 1 || echo 0)"

# --- refuse_defaulted_config_change ------------------------------------------
#
# `sudo FORCE=1 bash script/lightsail_launch.sh` reads as "converge this host",
# but a re-run applies every setting, so an override used once and not repeated
# is applied as its default. Two of those defaults rotate rather than converge:
# APP_SSH_USER moves docker + sudo + the sudoers.d grant off the account
# KAMAL_SSH_USER names, and DB_USER moves table ownership and LOGIN off the role
# in the deployed DATABASE_URL. A third, BACKUP_S3_URI, is the quiet one — the
# nightly dump keeps being written and stops leaving the instance.

# The setting list comes out of the script rather than being retyped here: a
# copy would keep passing after a setting was added to one and not the other,
# which is exactly the drift this guard exists to catch.
eval "$(awk '/^LAUNCH_SETTINGS=/ { f = 1 } f { print } f && /'"'"'$/ { exit }' "$SRC")"
[ -n "${LAUNCH_SETTINGS:-}" ] ||
  { echo "  FAIL could not extract LAUNCH_SETTINGS from $SRC"; fail=1; }

# $1 = state dir, $2 = space-separated supplied settings, rest = env assignments.
# The settings not named in the environment take the script's own defaults, which
# is the case under test — so they are spelled here once, as the script spells
# them, and each case overrides only what it is about.
run_cfg() {
  local state="$1" supplied="$2"; shift 2
  CFG_STATUS=0
  CFG_OUT="$(
    env SSH_PUBLIC_KEY= APP_SSH_USER=collavre PG_MAJOR=17 \
        DB_NAME=collavre_production DB_USER=collavre_user \
        DB_BIND_ADDRESS=172.17.0.1 DOCKER_SUBNETS=172.16.0.0/12 \
        SWAP_SIZE_MB=2048 TIMEZONE=Asia/Seoul INSTANCE_HOSTNAME=collavre \
        BACKUP_RETENTION_DAYS=7 BACKUP_S3_URI= BACKUP_AT=03:30 \
        LAUNCH_SETTINGS="$LAUNCH_SETTINGS" "$@" \
      bash -c '
        set -uo pipefail
        '"$(declare -f die refuse_defaulted_config_change)"'
        log() { echo "[log] $*"; }
        refuse_defaulted_config_change "$1" "$2"
      ' _ "$state" " $supplied " 2>&1
  )" || CFG_STATUS=$?
}

cfg=$(mktemp -d)
cat > "$cfg/launch.env" <<'ENV'
SSH_PUBLIC_KEY=ssh-ed25519 AAAAC3Nz key@host
APP_SSH_USER=deploybot
PG_MAJOR=17
DB_NAME=collavre_production
DB_USER=collavre_app
DB_BIND_ADDRESS=172.17.0.1
DOCKER_SUBNETS=172.16.0.0/12
SWAP_SIZE_MB=2048
TIMEZONE=Asia/Seoul
INSTANCE_HOSTNAME=collavre
BACKUP_RETENTION_DAYS=7
BACKUP_S3_URI=s3://collavre-backups/pg
BACKUP_AT=03:30
ENV

echo "107. a bare re-run of an overridden host is refused before anything moves"
run_cfg "$cfg" ""
chk "refused"                        1 "$CFG_STATUS"
chk "the deploy-user rotation named" 1 \
  "$(grep -c "APP_SSH_USER: host has 'deploybot'" <<<"$CFG_OUT")"
chk "the db-role rotation named"     1 \
  "$(grep -c "DB_USER: host has 'collavre_app'" <<<"$CFG_OUT")"
chk "and the quiet one too"          1 \
  "$(grep -c "BACKUP_S3_URI: host has 's3://collavre-backups/pg'" <<<"$CFG_OUT")"
chk "and the withdrawn key too"      1 \
  "$(grep -c "SSH_PUBLIC_KEY: host has 'ssh-ed25519 AAAAC3Nz key@host'" <<<"$CFG_OUT")"
chk "settings that agree are not"    0 "$(grep -c 'PG_MAJOR' <<<"$CFG_OUT")"
chk "and it says nothing changed"    1 "$(grep -c 'Nothing has been changed' <<<"$CFG_OUT")"

echo "108. the command it prints to recover is one that actually clears it"
# The remedy, not just the finding: a refusal that prints an incantation nobody
# checked is how a guard becomes a dead end. Replay exactly what it said —
# including which settings it named, rather than a list written here, or the
# second run would be told they were supplied whatever the message said and
# would pass with an empty replay.
replay="$(sed -n 's/^ *sudo \(.*\)FORCE=1 bash script.*/\1/p' <<<"$CFG_OUT")"
chk "it printed a replay command"    1 "$([ -n "$replay" ] && echo 1 || echo 0)"
# eval, not word-splitting: the SSH key holds spaces, so the printed line is
# only a recovery if a shell's own parsing of it is. %q is what makes that true.
eval "replay_args=($replay)"
replay_names="$(printf '%s\n' "${replay_args[@]}" | sed 's/=.*//' | tr '\n' ' ')"
run_cfg "$cfg" "$replay_names" "${replay_args[@]}"
chk "and replaying it goes through"  0 "$CFG_STATUS"
chk "it replayed the key intact"     1 \
  "$(printf '%s\n' "${replay_args[@]}" |
     grep -cx 'SSH_PUBLIC_KEY=ssh-ed25519 AAAAC3Nz key@host')"

echo "109. naming a setting is an instruction, not an omission"
# The deliberate rotations this page documents must not need an acknowledgement.
run_cfg "$cfg" "APP_SSH_USER DB_USER BACKUP_S3_URI SSH_PUBLIC_KEY" \
  APP_SSH_USER=newbot DB_USER=collavre_app BACKUP_S3_URI=s3://collavre-backups/pg \
  SSH_PUBLIC_KEY='ssh-ed25519 AAAAC3Nz key@host'
chk "a named rotation is allowed"    0 "$CFG_STATUS"
chk "and nothing is reported"        "" "$CFG_OUT"

echo "110. ACK_CONFIG_RESET=1 applies the defaults and says which"
run_cfg "$cfg" "" ACK_CONFIG_RESET=1
chk "allowed"                        0 "$CFG_STATUS"
chk "and it names what it reset"     1 \
  "$(grep -c "APP_SSH_USER: host has 'deploybot'" <<<"$CFG_OUT")"

echo "111. a host provisioned before launch.env existed is still guarded"
# The upgrade path. Only the two settings that rotate a credential are
# answerable from the files that predate launch.env — and the assertion says so
# rather than implying the others are safe.
legacy=$(mktemp -d)
printf 'deploybot\n' > "$legacy/deploy_user"
printf 'collavre_app\n' > "$legacy/db_user"
run_cfg "$legacy" ""
chk "refused"                        1 "$CFG_STATUS"
chk "deploy user recovered"          1 \
  "$(grep -c "APP_SSH_USER: host has 'deploybot'" <<<"$CFG_OUT")"
chk "db role recovered"              1 \
  "$(grep -c "DB_USER: host has 'collavre_app'" <<<"$CFG_OUT")"
chk "and S3 is not claimed to be checked" 0 "$(grep -c 'BACKUP_S3_URI' <<<"$CFG_OUT")"
# The file it sends the operator to has to be one that is there. This branch
# exists *because* launch.env is absent, so naming it as "the host's own record"
# is wrong on exactly the path that prints it — and it reads as "your record is
# missing" at the moment the operator is being asked to reconstruct a command.
chk "it does not cite the absent file" 0 \
  "$(grep -c "record of what it was given is $legacy/launch.env" <<<"$CFG_OUT")"
chk "it names the files that answered" 1 \
  "$(grep -c "$legacy/deploy_user, $legacy/db_user" <<<"$CFG_OUT")"
chk "and says the rest is on you"      1 \
  "$(grep -c 'could not be checked at all' <<<"$CFG_OUT")"

echo "111a. only the files that actually answered are cited"
# A directory listing would do; naming the file whose value refused is what
# makes the citation checkable by the operator reading it.
half=$(mktemp -d)
printf 'deploybot\n' > "$half/deploy_user"
run_cfg "$half" ""
chk "refused"                        1 "$CFG_STATUS"
chk "the file that answered named"   1 "$(grep -c "$half/deploy_user" <<<"$CFG_OUT")"
chk "and db_user is not invented"    0 "$(grep -c 'db_user' <<<"$CFG_OUT")"
rm -rf "$half"
rm -rf "$legacy"

echo "112. a first run has nothing to disagree with"
fresh=$(mktemp -d)
run_cfg "$fresh" ""
chk "allowed"                        0 "$CFG_STATUS"
chk "and silent"                     "" "$CFG_OUT"
rm -rf "$fresh"

echo "113. the password is not one of the settings recorded in launch.env"
# launch.env is 0644 on purpose — the runbook sends operators to read it — and
# DB_PASSWORD has its own 0600 file. Listing it here would move the production
# password into a world-readable one.
chk "DB_PASSWORD is not tracked"     0 \
  "$(grep -cw 'DB_PASSWORD' <<<"$LAUNCH_SETTINGS")"
rm -rf "$cfg"

echo "114. the guard is called before anything it protects"
# A refusal that says "Nothing has been changed" has to be true, and everything
# below rotates or installs. Asserted on the call site rather than on the
# function, because the function being correct is not what makes the message
# true — its position is.
call_line="$(grep -n '^refuse_defaulted_config_change$' "$SRC" | head -1 | cut -d: -f1)"
chk "it is called at all"            1 "$([ -n "$call_line" ] && echo 1 || echo 0)"
for after in 'apt_get update' 'ensure_sudoers "\$APP_SSH_USER"' \
             'usermod -aG docker' 'revoke_prior_deploy_user "\$APP_SSH_USER"' \
             'reassign_prior_db_role "\$DB_USER"'; do
  line="$(grep -n "^$after" "$SRC" | head -1 | cut -d: -f1)"
  chk "before ${after%% *}" 1 \
    "$([ -n "$line" ] && [ "$call_line" -lt "$line" ] && echo 1 || echo 0)"
done

echo "115. no procedure on the page walks the operator into this refusal blind"
# The guard is only a stop rather than a trap if the page that prints re-runs
# says what a re-run has to repeat. §2 does; a recipe elsewhere that names one
# setting and stops mid-procedure — app down, old cluster already dropped — is
# the same refusal reached at the worst moment. So every FORCE=1 invocation on
# the page has to carry the record with it: named in the command itself, or
# within reading distance of it.
#
# Scoped to the enclosing section rather than to a window of N lines: the unit
# an operator reads is the procedure they are following, and a section boundary
# is where they stopped reading. A window would also pass or fail on how the
# prose happens to be wrapped.
heads="$(grep -n '^#\{2,\} ' "$DOC" | cut -d: -f1)"
while IFS=: read -r n _; do
  [ -n "$n" ] || continue
  from=1; to="$(wc -l < "$DOC")"
  for h in $heads; do
    [ "$h" -le "$n" ] && from="$h"
    if [ "$h" -gt "$n" ]; then to=$(( h - 1 )); break; fi
  done
  chk "FORCE=1 at doc line $n cites launch.env, in the section that prints it" 1 \
    "$([ "$(sed -n "${from},${to}p" "$DOC" | grep -c 'launch\.env')" -gt 0 ] &&
       echo 1 || echo 0)"
done <<<"$(grep -n 'FORCE=1' "$DOC" | grep -E 'lightsail_launch\.sh|launch script')"

echo "116. the DB_USER escape hatch operates on the database the host records"
# The two blocks under "Changing DB_USER on a re-run" are the way out of a run
# that has already stopped, and they named collavre_production. On a host that
# followed the rename procedure further down the same page they connect to a
# database that is not there — and the check block's success signal was "empty
# output", which is what a psql that cannot connect leaves on stdout while its
# FATAL goes to stderr. So the escape hatch reported a finished transfer for a
# connection it never made.
xfer="$(extract_recipe 'OWNER TO %I')"
ownck="$(extract_recipe 'asked=yes')"
chk "the transfer names no database of its own" 0 \
  "$(grep -c 'collavre_production' <<<"$xfer")"
chk "nor does the check"                        0 \
  "$(grep -c 'collavre_production' <<<"$ownck")"
chk "the name comes from managed state"         1 \
  "$(grep -cq '/var/lib/collavre/db_name' <<<"$(extract_recipe 'could not read the database name')" \
     && echo 1 || echo 0)"

# Runs the extracted check block against a psql that cannot connect, one that
# reports rows still owned, and one that reports none.
run_ownck() {
  local work; work="$(mktemp -d)"
  mkdir -p "$work/bin"
  cat > "$work/bin/sudo" <<'SUDO'
#!/usr/bin/env bash
while [ "$#" -gt 0 ]; do case "$1" in -u) shift 2 ;; *) break ;; esac; done
exec "$@"
SUDO
  # The stub writes its refusal to stderr and leaves stdout empty, the way psql
  # does — asserting that split is the whole point of the case.
  cat > "$work/bin/psql" <<'PSQL'
#!/usr/bin/env bash
case "$MODE" in
  fail)  echo 'psql: error: FATAL:  database "x" does not exist' >&2; exit 2 ;;
  rows)  echo 'r|creatives'; exit 0 ;;
  clean) exit 0 ;;
esac
PSQL
  chmod +x "$work/bin/sudo" "$work/bin/psql"
  printf 'app_db=the_db\n%s' "$ownck" > "$work/check.sh"
  OWNCK_OUT="$(PATH="$work/bin:$PATH" MODE="$1" bash "$work/check.sh" 2>/dev/null)"
  rm -rf "$work"
}

run_ownck fail
chk "an unanswerable check says so"    1 "$(grep -c 'COULD NOT CHECK' <<<"$OWNCK_OUT")"
chk "and does not report completion"   0 "$(grep -c 'TRANSFER COMPLETE' <<<"$OWNCK_OUT")"
run_ownck rows
chk "rows left are reported"           1 "$(grep -c 'STILL OWNED BY' <<<"$OWNCK_OUT")"
chk "not as completion"                0 "$(grep -c 'TRANSFER COMPLETE' <<<"$OWNCK_OUT")"
run_ownck clean
chk "a clean database is completion"   1 "$(grep -c 'TRANSFER COMPLETE' <<<"$OWNCK_OUT")"

# The negative control. There is no assertion-shaped one against the previous
# revision — that block printed no verdict at all, the prose carried it — so the
# discrimination is measured directly instead: under the old form the failed
# connection and the finished transfer are the same two bytes of stdout.
prevdir="$(mktemp -d)"; mkdir -p "$prevdir/bin"
cat > "$prevdir/bin/sudo" <<'SUDO'
#!/usr/bin/env bash
while [ "$#" -gt 0 ]; do case "$1" in -u) shift 2 ;; *) break ;; esac; done
exec "$@"
SUDO
cat > "$prevdir/bin/psql" <<'PSQL'
#!/usr/bin/env bash
case "$MODE" in
  fail)  echo 'psql: error: FATAL:  database "x" does not exist' >&2; exit 2 ;;
  clean) exit 0 ;;
esac
PSQL
chmod +x "$prevdir/bin/sudo" "$prevdir/bin/psql"
echo 'sudo -u postgres psql -qtA -d collavre_production -c "SELECT 1"' > "$prevdir/prev.sh"
prev_fail="$(PATH="$prevdir/bin:$PATH" MODE=fail  bash "$prevdir/prev.sh" 2>/dev/null)"
prev_ok="$(  PATH="$prevdir/bin:$PATH" MODE=clean bash "$prevdir/prev.sh" 2>/dev/null)"
chk "the previous form could not tell them apart" "$prev_ok" "$prev_fail"
rm -rf "$prevdir"
# Not vacuous on its own — two empty strings compare equal for any reason at
# all, including a stub that never ran. What makes it a control is that the
# same two states are distinguishable under the new form.
run_ownck fail;  new_fail="$OWNCK_OUT"
run_ownck clean; new_ok="$OWNCK_OUT"
chk "where the new form does"          1 \
  "$([ "$new_fail" != "$new_ok" ] && echo 1 || echo 0)"
chk "and the old form said nothing at all" "" "$prev_ok"

echo "117. the grant is recorded before it is made, not after"
# Asserted on the call site rather than on the function, for the same reason as
# case 114: the function being correct is not what closes the interruption
# window — its position is. A record written after the grants describes only
# runs that reached the end, and the run that matters is the one that did not.
# Not anchored at the end: the call carries a `|| log ...` continuation, and an
# end-anchored pattern matches nothing while still looking like an assertion
# about position. It cannot match the definition, which ends in `() {`.
rec_line="$(grep -n '^record_deploy_user_grant "\$APP_SSH_USER"' "$SRC" | head -1 | cut -d: -f1)"
chk "it is called at all"                 1 "$([ -n "$rec_line" ] && echo 1 || echo 0)"
for after in 'usermod -aG sudo "\$APP_SSH_USER"' 'usermod -aG docker "\$APP_SSH_USER"' \
             'revoke_prior_deploy_user "\$APP_SSH_USER"'; do
  line="$(grep -n "^$after" "$SRC" | head -1 | cut -d: -f1)"
  chk "before ${after%% \"*}" 1 \
    "$([ -n "$line" ] && [ "$rec_line" -lt "$line" ] && echo 1 || echo 0)"
done

echo "118. a name PostgreSQL takes but this script cannot use is refused"
# format('%I') quotes whatever it is given, so the cluster accepts names that
# then break outside SQL. Measured on a live cluster: DB_NAME='tenant/prod' is
# created, pg_dump connects to it, and the nightly dump's --file lands under a
# directory that does not exist — so the host runs and every backup fails.
idg_out=''
idg() {
  idg_out="$( ( refuse_unusable_db_identifier "$1" "$2" ) 2>&1 )"
  idg_status=$?
}
for good in collavre_production collavre_prod collavre-prod collavre_user \
            postgres CollavreProd db1; do
  idg DB_NAME "$good"
  chk "accepted: $good"                   0 "$idg_status"
done
# A '/' is the measured one; the rest are the same class one character over —
# a quote breaks the CREATE statements, which take both settings as string
# literals, and a leading '-' is an option to every command that later handles
# the dump file.
for bad in 'tenant/prod' "a'b" 'a b' '-prod' 'a;b' 'a$b' ''; do
  idg DB_NAME "$bad"
  chk "refused: ${bad:-(empty)}"          1 "$idg_status"
done
idg DB_NAME 'tenant/prod'
chk "says nothing was changed"            1 "$(grep -c 'Nothing has been changed' <<<"$idg_out")"
# Without a way out this is a dead end rather than a guard: refuse_db_name_change
# refuses any *other* name on a host already provisioned under the bad one, so
# the refusal has to name the procedure that moves the host off it.
chk "and names the way off such a host"   1 "$(grep -c 'Changing DB_NAME on a re-run' <<<"$idg_out")"

echo "118a. the ranges are byte ranges, not whatever the host collates"
# `[A-Za-z]` is a collation range, not a byte range, and under some collations
# it matches accented letters — which is exactly the class of name this exists
# to keep out of a filesystem path.
lc_probe() { local LC_ALL="$1"
  case "$2" in ''|-*|*[!A-Za-z0-9_-]*) echo REFUSE ;; *) echo ACCEPT ;; esac; }
chk "the guard pins LC_ALL=C"             1 \
  "$(sed -n '/^refuse_unusable_db_identifier() {/,/^}/p' "$SRC" | grep -c 'local LC_ALL=C')"
chk "and under C the bytes are out"       REFUSE "$(lc_probe C 'café')"
# Whether the pin can be *demonstrated* depends on a disagreeing collation being
# installed, which macOS has and a minimal CI container may not — measured on
# macOS/bash 3.2 under en_US.UTF-8: ACCEPT. Reported as undemonstrated rather
# than asserted into a pass, so this does not become a check that is green
# because the host had nothing to check with.
drifting=''
for cand in en_US.UTF-8 en_US.utf8 C.UTF-8; do
  [ "$(lc_probe "$cand" 'café')" = ACCEPT ] && { drifting="$cand"; break; }
done
if [ -n "$drifting" ]; then
  echo "  ok   $drifting accepts what C refuses — the pin is load-bearing here"
else
  echo "  --   no installed collation disagrees here; pin asserted, not demonstrated"
fi

echo "118b. no example on the page is refused by it"
# The failure this shape has: a new fail-closed guard that turns out to refuse
# the runbook's own instructions.
while read -r ex; do
  [ -n "$ex" ] || continue
  idg DB_NAME "$ex"
  chk "the page's own $ex is accepted"    0 "$idg_status"
done <<<"$(grep -ohE '\b(DB_NAME|DB_USER)=[A-Za-z0-9_.-]+' "$DOC" | cut -d= -f2 | sort -u)"

echo "118c. it is called before anything it protects, and reads no state"
# Same reason as case 114. A value this script cannot use is not usable whatever
# the host was given earlier, so it is answered before the guard that reads
# $STATE_DIR — and long before anything is installed.
idn_line="$(grep -n '^refuse_unusable_db_identifier DB_NAME' "$SRC" | head -1 | cut -d: -f1)"
chk "DB_NAME is checked"                  1 "$([ -n "$idn_line" ] && echo 1 || echo 0)"
chk "so is DB_USER"                       1 \
  "$(grep -c '^refuse_unusable_db_identifier DB_USER' "$SRC")"
# Anchored at both ends: the pattern without it matches the function's own
# definition line, which is above the call and would make this pass for the
# wrong reason.
cfg_call="$(grep -n '^refuse_defaulted_config_change$' "$SRC" | head -1 | cut -d: -f1)"
chk "before refuse_defaulted_config_change" 1 \
  "$([ -n "$cfg_call" ] && [ "$idn_line" -lt "$cfg_call" ] && echo 1 || echo 0)"
for after in 'apt_get update' \
             'ensure_sudoers "\$APP_SSH_USER"' 'usermod -aG docker'; do
  line="$(grep -n "^$after" "$SRC" | head -1 | cut -d: -f1)"
  chk "before ${after%% *}" 1 \
    "$([ -n "$line" ] && [ "$idn_line" -lt "$line" ] && echo 1 || echo 0)"
done

echo "119. an SSH key sshd cannot read is refused before it is appended"
# Real keys here, not the synthetic 'ssh-ed25519 AAAAKEYA x' fixtures the rest of
# this suite uses: what is under test is whether sshd's own parser accepts the
# line, and no fixture can stand in for that. The truncation is 24 characters out
# of the base64 body, which is what a paste that lost its tail looks like — and
# the one form a length or prefix check cannot catch.
if ! command -v ssh-keygen >/dev/null 2>&1; then
  echo "  SKIP no ssh-keygen here — the guard's own dependency is missing"
else
  kd="$(mktemp -d)"
  ssh-keygen -q -t ed25519 -N '' -C 'operator@laptop' -f "$kd/old" >/dev/null
  ssh-keygen -q -t ed25519 -N '' -C 'operator@newlaptop' -f "$kd/new" >/dev/null
  GOOD_OLD="$(cat "$kd/old.pub")"; GOOD_NEW="$(cat "$kd/new.pub")"
  nbody="${GOOD_NEW#* }"; nbody="${nbody%% *}"
  TBODY="${nbody:0:${#nbody} - 24}"
  TRUNC="${GOOD_NEW%% *} $TBODY operator@newlaptop"

  g_out=''; g_rc=0
  guard() {
    g_out="$( ( log() { echo "[log] $*"; }
                SSH_PUBLIC_KEY="$1" APP_SSH_USER=collavre
                refuse_unparsable_ssh_key ) 2>&1 )" && g_rc=0 || g_rc=1
  }

  guard "$GOOD_NEW"
  chk "a real key goes through"                 0 "$g_rc"
  guard ""
  chk "and so does none at all"                 0 "$g_rc"
  guard "${GOOD_NEW% *}"
  chk "and one with no comment"                 0 "$g_rc"
  # authorized_keys lines may carry restrictions, and a shape check strict enough
  # to catch truncation would refuse these — which is why the guard parses.
  guard "no-pty,no-agent-forwarding $GOOD_NEW"
  chk "and one behind a no-pty restriction"     0 "$g_rc"
  # A forced command still goes through *here*, and that is the point rather
  # than an oversight: this guard answers "can sshd read it", which for this
  # line is yes. The reason it must not be the whole answer is case 142, where
  # the run refuses it a guard later — sshd reads it and then runs that command
  # instead of Kamal's. The example used to be spelled `command="x",no-pty` on
  # this row, which read as this suite endorsing the line rather than as one
  # question of two.
  guard "command=\"x\",no-pty $GOOD_NEW"
  chk "a forced command is still parsable"      0 "$g_rc"
  guard "from=\"10.0.0.0/8\" $GOOD_NEW"
  chk "and one behind a from= restriction"      0 "$g_rc"
  guard "   $GOOD_NEW"
  chk "and one with leading whitespace"         0 "$g_rc"

  guard "hello world"
  chk "text that is not a key is refused"       1 "$g_rc"
  # `grep -qxF` treats each line of its pattern as a pattern of its own, so a
  # two-line value is "in place" as soon as either half of it is and the
  # withdrawal proceeds on half a key.
  guard "$GOOD_NEW"$'\n'"$GOOD_OLD"
  chk "and a value holding a newline"           1 "$g_rc"

  guard "$TRUNC"
  chk "and a truncated paste"                   1 "$g_rc"
  chk "it says nothing has been changed"        1 \
    "$(grep -c 'Nothing has been changed' <<<"$g_out")"
  # An operator who pastes a private key by mistake is exactly what this refuses,
  # and the provisioning log is not private.
  chk "and does not echo the value"             0 "$(grep -cF "$TBODY" <<<"$g_out")"

  # The control is the failure itself, not an earlier form of the guard: the guard
  # is new, so there is nothing to run against. What has to be established is that
  # the functions behind it really do end at zero usable keys — otherwise this is
  # machinery against nothing.
  usable_keys() {
    local n=0 line probe; probe="$(mktemp)"
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      printf '%s\n' "$line" > "$probe"
      ssh-keygen -l -f "$probe" >/dev/null 2>&1 && n=$((n + 1))
    done < "$1"
    rm -f "$probe"; printf '%s\n' "$n"
  }
  kh="$(mktemp -d)"; mkdir -p "$kh/collavre/.ssh"
  kauth="$kh/collavre/.ssh/authorized_keys"
  printf '%s\n' "$GOOD_OLD" > "$kauth"
  ksd="$(mktemp -d)"; printf '%s\n' "$GOOD_OLD" > "$ksd/ssh_public_key.collavre"
  chk "the predecessor is usable to begin with" 1 "$(usable_keys "$kauth")"
  ( STATE_DIR="$ksd" APP_SSH_USER=collavre SSH_PUBLIC_KEY="$TRUNC"
    log() { :; }
    install_authorized_keys "$kauth" "$kh"
    revoke_prior_ssh_key "$kauth"
    dedupe_authorized_keys "$kauth" "$SSH_PUBLIC_KEY" ) >/dev/null 2>&1
  chk "unguarded, no key sshd can read is left" 0 "$(usable_keys "$kauth")"
  chk "the predecessor was withdrawn"           0 "$(grep -cxF "$GOOD_OLD" "$kauth")"
  # The two checks that would otherwise have caught it, and do not.
  chk "while the file is not empty"             1 \
    "$([ -s "$kauth" ] && echo 1 || echo 0)"
  chk "and the marker names the unusable key"   1 \
    "$(grep -cxF "$TRUNC" "$ksd/ssh_public_key.collavre")"
fi

echo "119a. where ssh-keygen is absent it warns and lets the run continue"
# Absence cannot be modelled by hiding the binary from this shell, since
# everything the case needs would go with it. A PATH holding only what the
# extracted function uses is the seam — and the first assertion is what makes the
# rest worth anything: without it the case passes on a PATH where ssh-keygen is
# still in reach, which is the shape of vacuous pass this suite has hit before.
kbin="$(mktemp -d)"
for kc in bash mktemp rm; do ln -s "$(command -v "$kc")" "$kbin/$kc"; done
kfns="$(mktemp)"; declare -f die refuse_unparsable_ssh_key > "$kfns"
krun="$(mktemp)"
cat > "$krun" <<'RUN'
set -uo pipefail
log() { echo "[log] $*"; }
. "$FNS"
APP_SSH_USER=collavre
command -v ssh-keygen >/dev/null 2>&1 && echo visible=yes || echo visible=no
refuse_unparsable_ssh_key && echo rc=0 || echo rc=1
RUN
kout="$(PATH="$kbin" FNS="$kfns" SSH_PUBLIC_KEY='ssh-ed25519 CUT-SHORT op@laptop' \
        bash "$krun" 2>&1)"
chk "ssh-keygen really is out of reach"    1 "$(grep -c 'visible=no' <<<"$kout")"
chk "it does not refuse the run"           1 "$(grep -cx 'rc=0' <<<"$kout")"
chk "it says the key was not checked"      1 "$(grep -c 'could not be' <<<"$kout")"
chk "and names the account at risk"        1 "$(grep -c 'log in as collavre' <<<"$kout")"

echo "119b. it is called before anything that could leave the account keyless"
# Anchored at both ends so the pattern does not match the function's own
# definition line, which is above the call.
grd_line="$(grep -n '^refuse_unparsable_ssh_key$' "$SRC" | head -1 | cut -d: -f1)"
chk "the guard is called at all"           1 "$([ -n "$grd_line" ] && echo 1 || echo 0)"
for after in 'install_authorized_keys "\$AUTH_KEYS"' \
             'revoke_prior_ssh_key "\$AUTH_KEYS"' \
             'dedupe_authorized_keys "\$AUTH_KEYS"' \
             'apt_get update' 'usermod -aG docker'; do
  line="$(grep -n "^$after" "$SRC" | head -1 | cut -d: -f1)"
  # Both operands tested for emptiness before the comparison: against a script
  # with no call at all these are all meant to fail, and `[ "" -lt 5 ]` fails
  # with a shell error rather than an answer, which buries the assertion it was
  # supposed to report.
  chk "before ${after%% *}" 1 \
    "$([ -n "$grd_line" ] && [ -n "$line" ] && [ "$grd_line" -lt "$line" ] &&
       echo 1 || echo 0)"
done

# --- a record that does not answer is not a record of "nothing to check" ------
#
# launch.env is written with one redirection at the very end of a run, and
# refuse_defaulted_config_change branches on the file *existing*. A write that
# failed after the truncate — a full disk, an interrupted run — leaves it
# present and short, and every missing line is skipped by the reader's
# `grep -q "^$name=" || continue`. So the guard answered "no drift" about a
# comparison it never made, and what went through is the bare `FORCE=1` re-run
# it exists to refuse.

cfg_short=$(mktemp -d)
printf 'deploybot\n'    > "$cfg_short/deploy_user"
printf 'collavre_app\n' > "$cfg_short/db_user"

echo "120. a launch.env that cannot answer falls back to the markers that can"
: > "$cfg_short/launch.env"
run_cfg "$cfg_short" ""
chk "an empty record: refused"        1 "$CFG_STATUS"
chk "the deploy-user rotation named"  1 \
  "$(grep -c "APP_SSH_USER: host has 'deploybot'" <<<"$CFG_OUT")"
chk "the db-role rotation named"      1 \
  "$(grep -c "DB_USER: host has 'collavre_app'" <<<"$CFG_OUT")"

# Truncated mid-line, which is what a redirection killed part-way through
# actually leaves: the settings before the cut survive and the rest are gone.
# SSH_PUBLIC_KEY is empty on both sides here, so nothing but the fallback can
# produce a refusal — a case that passed on the surviving line would prove
# nothing about the lines that did not survive.
printf 'SSH_PUBLIC_KEY=\nAPP_SSH_U' > "$cfg_short/launch.env"
run_cfg "$cfg_short" ""
chk "a truncated record: refused"     1 "$CFG_STATUS"
chk "the setting cut off mid-line"    1 \
  "$(grep -c "APP_SSH_USER: host has 'deploybot'" <<<"$CFG_OUT")"

# The control that keeps this from being a guard that fires on everything: a
# record that does answer and agrees must still proceed, and the fallback must
# not re-fire on a setting launch.env already settled. The markers here name
# somebody else on purpose — if the fallback ran unconditionally this would
# refuse a host where nothing drifted.
{ for _n in $LAUNCH_SETTINGS; do
    case "$_n" in
      APP_SSH_USER) echo "APP_SSH_USER=collavre" ;;
      DB_USER)      echo "DB_USER=collavre_user" ;;
      PG_MAJOR)     echo "PG_MAJOR=17" ;;
      DB_NAME)      echo "DB_NAME=collavre_production" ;;
      DB_BIND_ADDRESS) echo "DB_BIND_ADDRESS=172.17.0.1" ;;
      DOCKER_SUBNETS)  echo "DOCKER_SUBNETS=172.16.0.0/12" ;;
      SWAP_SIZE_MB) echo "SWAP_SIZE_MB=2048" ;;
      TIMEZONE)     echo "TIMEZONE=Asia/Seoul" ;;
      INSTANCE_HOSTNAME) echo "INSTANCE_HOSTNAME=collavre" ;;
      BACKUP_RETENTION_DAYS) echo "BACKUP_RETENTION_DAYS=7" ;;
      BACKUP_AT)    echo "BACKUP_AT=03:30" ;;
      *)            echo "$_n=" ;;
    esac
  done; } > "$cfg_short/launch.env"
unset _n
run_cfg "$cfg_short" ""
chk "a record that agrees: proceeds"  0 "$CFG_STATUS"
chk "and says nothing"                "" "$CFG_OUT"

echo "120a. against the previous form the empty record went straight through"
# The previous reader inline, so what differs is the branch and not a second
# copy of the function. Everything else — the setting list, the markers, the
# environment — is the case above.
: > "$cfg_short/launch.env"
prev_status=0
prev_out="$(
  env SSH_PUBLIC_KEY= APP_SSH_USER=collavre DB_USER=collavre_user \
      LAUNCH_SETTINGS="$LAUNCH_SETTINGS" \
    bash -c '
      set -uo pipefail
      state_dir="$1"; env_file="$state_dir/launch.env"; drift=""
      if [ -f "$env_file" ]; then
        for name in $LAUNCH_SETTINGS; do
          grep -q "^$name=" "$env_file" || continue
          prior="$(sed -n "s/^$name=//p" "$env_file" | head -1)"
          [ "$prior" = "${!name}" ] && continue
          drift="$drift $name"
        done
      else
        for pair in deploy_user:APP_SSH_USER db_user:DB_USER; do
          file="${pair%%:*}"; name="${pair##*:}"
          [ -f "$state_dir/$file" ] || continue
          prior="$(cat "$state_dir/$file")"
          [ -n "$prior" ] && [ "$prior" != "${!name}" ] && drift="$drift $name"
        done
      fi
      [ -z "$drift" ] || { echo "REFUSING:$drift"; exit 1; }
    ' _ "$cfg_short" 2>&1
)" || prev_status=$?
chk "the previous form: NOT refused"  0 "$prev_status"
chk "and silent about the rotation"   0 "$(grep -c APP_SSH_USER <<<"$prev_out")"

echo "120b. launch.env is replaced in one step rather than truncated in place"
# The assertion is on the write, not on the wording: a redirection here is the
# defect, whatever the comment above it says.
lenv_line="$(grep -c 'write_state_file "\$state_dir/launch.env"' "$SRC")"
chk "written through write_state_file" 1 "$lenv_line"
chk "and not by a redirection"         0 \
  "$(grep -c '> *"\$STATE_DIR/launch.env"' "$SRC")"

# --- an empty db_password is a password this host cannot name ----------------
#
# Same window, and the consequence is worse: the empty value is read back as
# the password and reaches `ALTER ROLE ... PASSWORD ''` unconditionally, so the
# live role is rotated to an empty password while the deployed DATABASE_URL
# still carries the real one. The app meets `password authentication failed` at
# its next reconnect, and the value it needs is gone from the host.
echo "121. an empty db_password marker is refused rather than applied"
pw_recipe="$(awk '/^if \[ -z "\$DB_PASSWORD" \]; then$/ { f = 1 }
                  f { print }
                  f && /^fi$/ { exit }' "$SRC")"
chk "the block was extracted" 1 \
  "$(grep -q 'STATE_DIR/db_password' <<<"$pw_recipe" && echo 1 || echo 0)"

run_pw() {   # run_pw <state dir>
  PW_STATUS=0
  PW_OUT="$(
    env STATE_DIR="$1" DB_PASSWORD= \
      bash -c '
        set -uo pipefail
        '"$(declare -f die)"'
        log() { echo "[log] $*"; }
        '"$pw_recipe"'
        echo "APPLIED:$DB_PASSWORD"
      ' 2>&1
  )" || PW_STATUS=$?
}

pwd_dir=$(mktemp -d)
: > "$pwd_dir/db_password"
run_pw "$pwd_dir"
chk "an empty marker: refused"    1 "$PW_STATUS"
chk "nothing was applied"         0 "$(grep -c '^APPLIED:' <<<"$PW_OUT")"
chk "it says what it cannot name" 1 "$(grep -c 'cannot name' <<<"$PW_OUT")"
# The recovery has to be reachable, not just named — an operator who still has
# the deployed DATABASE_URL can decode the password out of it.
chk "and where to get it back"    1 "$(grep -c 'DATABASE_URL' <<<"$PW_OUT")"

printf 'realpassword' > "$pwd_dir/db_password"
run_pw "$pwd_dir"
chk "a marker with a value: kept" 0 "$PW_STATUS"
chk "and it is the one applied"   "APPLIED:realpassword" \
  "$(grep '^APPLIED:' <<<"$PW_OUT")"

rm -f "$pwd_dir/db_password"
run_pw "$pwd_dir"
chk "no marker at all: generates" 0 "$PW_STATUS"
chk "and it is not empty"         0 "$(grep -c '^APPLIED:$' <<<"$PW_OUT")"

echo "121a. the password marker is 0600 from the moment it exists"
# mktemp creates 0600 and write_state_file chmods before it writes, so the
# content never lands in a file that was briefly 0644 in a 0755 directory —
# which is what the `umask 077` subshell it replaces could only achieve by
# getting the umask right.
pwt=$(mktemp -d)
write_state_file "$pwt/db_password" "s3cret" 0600
chk "the value round-trips"   "s3cret" "$(cat "$pwt/db_password")"
chk "and the mode is 0600"    "600"    "$(file_mode "$pwt/db_password")"
write_state_file "$pwt/plain" "x"
chk "the default stays 0644"  "644"    "$(file_mode "$pwt/plain")"

echo "121b. a write that fails leaves the previous value in place"
# The property the redirection did not have. `ulimit -f 0` stands in for the
# full disk this fails on: the staging file is what gets truncated, and the
# marker the host depends on is untouched until the rename.
printf 'previous' > "$pwt/db_password"
{ ( ulimit -f 0; write_state_file "$pwt/db_password" "replacement" 0600 ); } 2>/dev/null
chk "the marker still reads"  "previous" "$(cat "$pwt/db_password")"

# --- the cluster serving DB_PORT has to be the one this script configures ----
echo "122. a same-version cluster that is not named 'main' is refused"
# Version and port agreeing is not enough. Everything downstream names
# /etc/postgresql/<major>/main as literal text — the tuning, listen_addresses,
# the pg_hba rule for the docker bridge, and the runbook's recovery blocks. On a
# host whose cluster is called something else that path is absent, the step-5
# apt install reports the package already present without creating a second
# cluster, `install -d` makes the missing directory, and all of it is written
# into a tree no postmaster reads. `systemctl restart postgresql` then succeeds,
# because the umbrella unit does not care which clusters exist, and the run
# reports success over containers that cannot reach the database.
PG_MAJOR=17
DB_PORT=5432
mk_lsclusters pg_ls_named_app '17  app     5432 online postgres /var/lib/postgresql/17/app /var/log/x'
out="$( (ensure_cluster_on_default_port pg_ls_named_app) 2>&1 )"
chk "exits non-zero" 1 "$?"
case "$out" in
  *"is named 'app', not 'main'"*"pg_renamecluster"*)
    echo "  ok   names the cluster it found and how to move it" ;;
  *) echo "  FAIL unhelpful message: $out"; fail=1 ;;
esac

# The controls. 'main' on the default port is the ordinary re-run and must not
# be refused, and a cluster of the WRONG version named 'app' must still be
# refused on the version — the name check must not preempt the answer that
# tells the operator to set PG_MAJOR.
mk_lsclusters pg_ls_named_main '17  main    5432 online postgres /var/lib/postgresql/17/main /var/log/x'
out="$( (ensure_cluster_on_default_port pg_ls_named_main) 2>&1 )"
chk "'main' on 5432: proceeds" 0 "$?"
chk "and says nothing"         "" "$out"

mk_lsclusters pg_ls_16_app '16  app     5432 online postgres /a /b'
out="$( (ensure_cluster_on_default_port pg_ls_16_app) 2>&1 )"
chk "a wrong-version 'app': refused" 1 "$?"
case "$out" in
  *"already serves 5432"*) echo "  ok   on the version, which is the useful answer" ;;
  *) echo "  FAIL reported the name over the version: $out"; fail=1 ;;
esac

echo "123. a UID 0 deploy user is refused before any account is touched"
# Step 3 writes PermitRootLogin no into sshd_config.d and then, further down the
# same step, arms $APP_SSH_USER and prints it as KAMAL_SSH_USER. Nothing between
# the two rejected the account sshd had just been told to turn away, so the run
# reported success over a host no deploy could authenticate to.
#
# shellcheck disable=SC2329  # called by refuse_root_deploy_user
id() { case "$2" in root|toor) echo 0 ;; collavre) echo 1001 ;; *) return 1 ;; esac; }
out="$( (refuse_root_deploy_user root) 2>&1 )"
chk "exits non-zero" 1 "$?"
case "$out" in
  *"PermitRootLogin no"*"KAMAL_SSH_USER=root"*"Nothing has been changed"*)
    echo "  ok   names the contradiction, not just the rule" ;;
  *) echo "  FAIL unhelpful: $out"; fail=1 ;;
esac
# By UID, not by the name. An account aliased to 0 is locked out by the same
# drop-in, and refusing only the literal 'root' would read as a check that had
# been done.
out="$( (refuse_root_deploy_user toor) 2>&1 )"
chk "an aliased UID 0 account is refused too" 1 "$?"

echo "123a. and an ordinary deploy user is not"
# The control that matters: this guard runs on every invocation, ahead of
# refuse_defaulted_config_change, so a false positive here refuses every run.
refuse_root_deploy_user collavre
chk "an existing ordinary account proceeds" 0 "$?"
# The default first-run shape. `id` fails because adduser has not run yet, and
# treating "cannot resolve" as "might be root" would refuse every fresh host.
refuse_root_deploy_user brand-new
chk "an account that does not exist yet proceeds" 0 "$?"
unset -f id

echo "124. the database markers are replaced, not truncated then filled"
# Same class as launch.env and db_password on this PR, and the reason the write
# is worth fixing rather than only the read: `>` truncates before it writes, so
# an interrupted run leaves the marker present and empty — and 97a is what an
# empty db_name then does to the guard. The two markers are checked through the
# helper the script now routes them through.
sd=$(mktemp -d)
printf 'collavre_production\n' > "$sd/db_name"
before=$(inode "$sd/db_name")
write_state_file "$sd/db_name" "collavre_renamed"$'\n'
chk "the value is replaced"          "collavre_renamed" "$(cat "$sd/db_name")"
chk "by rename, not in place"        1 "$([ "$(inode "$sd/db_name")" != "$before" ] && echo 1 || echo 0)"
chk "and the mode is the default"    644 "$(file_mode "$sd/db_name")"
# A staging write that fails must leave the previous value readable, which is
# the whole point: the reader has no way to tell an empty marker from a lost
# one, so it must never see either.
printf 'collavre_user\n' > "$sd/db_user"
mktemp() { return 1; }
write_state_file "$sd/db_user" "collavre_next"$'\n'
chk "a failed write reports it"                  1 "$?"
chk "and the previous value is still readable"   "collavre_user" "$(cat "$sd/db_user")"
unset -f mktemp
rm -rf "$sd"

# The assertions above pass against the previous revision too — write_state_file
# was already correct there, and the defect was that these two markers did not
# go through it. So the regression control is at the call site, in the source:
# nothing may replace a durable marker with a redirection, which is the one
# thing the behavioural cases cannot see.
chk "db_name is not written by redirection" \
  0 "$(grep -c '> *"\$STATE_DIR/db_name"' "$SRC")"
chk "db_user is not written by redirection" \
  0 "$(grep -c '> *"\$STATE_DIR/db_user"' "$SRC")"
chk "both go through write_state_file" \
  2 "$(grep -cE 'write_state_file "\$STATE_DIR/db_(name|user)"' "$SRC")"

echo "125. a torn queue append does not swallow the next value onto its line"
# The last write in this script that was not going through write_state_file, and
# the one it was introduced for. `grep -qxF x || printf '%s\n' x >> f` leaves a
# fragment with no newline when the append is cut short, and the *retry* is what
# does the damage: grep does not match the fragment, so the full value lands on
# the end of it and the queue holds one line that is neither.
#
# The fragment is injected rather than provoked. RLIMIT_FSIZE and ENOSPC both
# produce it, but neither is reachable from this harness on the maintainer's
# machine (`ulimit -f` would not cap an append here), and the partial write is
# not the claim — what the retry does to it is. Same reasoning as case 4a.
sd=$(mktemp -d)
KEYB="ssh-rsa AAAAB3NzaC1yc2ETESTKEYBBBBBBBBBBBBBBBBBBBBBBBBBBBB deploy@b"
printf 'ssh-rsa AAAAB3NzaC1yc2ETESTKEYAAAAAAAAAAAAAAAAAAAAAAAAAAAA deploy@a\n' \
  > "$sd/q"
printf '%s' "${KEYB:0:30}" >> "$sd/q"          # <- the torn append
append_state_line "$sd/q" "$KEYB"
chk "the recorded value gets a whole line of its own" \
  1 "$(grep -cxF "$KEYB" "$sd/q")"
chk "the fragment is terminated, not extended" \
  0 "$(grep -c "^${KEYB:0:30}${KEYB:0:4}" "$sd/q")"
chk "the value already present is not duplicated" \
  1 "$(append_state_line "$sd/q" "$KEYB"; grep -cxF "$KEYB" "$sd/q")"
# The control in the other direction: a queue that was never torn must come out
# byte-identical, since this runs on every convergence and a helper that
# rewrote every entry would churn a file three rotations depend on.
printf 'a\nb\n' > "$sd/q2"; before=$(cat "$sd/q2")
append_state_line "$sd/q2" b
chk "an entry already queued rewrites nothing" "$before" "$(cat "$sd/q2")"
append_state_line "$sd/q2" c
chk "and a new entry is appended in order"     "a b c" "$(tr '\n' ' ' < "$sd/q2" | sed 's/ $//')"
# A failed write must leave the previous queue readable: a truncated queue is
# how a root-equivalent key stops being named by anything.
mktemp() { return 1; }
append_state_line "$sd/q2" d
chk "a failed queue write reports it"          1 "$?"
chk "and the queue is still readable"          "a b c" "$(tr '\n' ' ' < "$sd/q2" | sed 's/ $//')"
unset -f mktemp
rm -rf "$sd"
# Source-level control. append_state_line is new, so the behavioural assertions
# above cannot fail against 6125e4ee — the suite would stop at its extraction
# check. The regression that can recur is a record_* function going back to a
# bare append, which is invisible until a write is cut short.
# Verified to read 3 against 6125e4ee and 0 here. Worth saying, because the
# first spelling of this pattern had one `.` too many and matched nothing in
# *either* revision — a zero-expectation assertion that an empty result
# satisfies silently, which is the same trap case 78b's dotenv control exists
# for.
chk "no queue is extended by a bare append" \
  0 "$(grep -cE 'printf .%s.n. "\$(user|role|key)" >> "\$set_file"' "$SRC")"
chk "all three record_* functions go through the helper" \
  3 "$(grep -c 'append_state_line "\$set_file"' "$SRC")"

echo "125a. a rotation past a torn queue entry does not strand the account"
# The end-to-end consequence of case 125's mechanism, and the reason the torn
# append is worse than a stale record rather than equivalent to one. The retry
# leaves `collavre_collavre_a` in the queue; the next rotation's loop tests
# `id -u` on it, finds no such account, and takes the `|| continue` path — which
# is correct for an account that is genuinely gone and wrong for a fragment.
# The queue then holds one name, the current user, and looks converged, while
# the account it was glued from keeps docker and sudo with nothing recording it.
sd=$(mktemp -d)
: > "$sd/groups"
# shellcheck disable=SC2329  # called by revoke_prior_deploy_user
id() { case "$1" in -u) grep -qx "$2" "$sd/accounts" ;; esac; }
# shellcheck disable=SC2329  # called by revoke_prior_deploy_user
revoke_deploy_user_access() { sed -i.bak "/^$1 /d" "$sd/groups"; }
printf 'collavre_a\ncollavre_b\n' > "$sd/accounts"

printf 'collavre_' > "$sd/deploy_users"          # the torn append
printf 'collavre_a docker sudo\n' >> "$sd/groups"
record_deploy_user_grant collavre_a "$sd/deploy_users" "$sd/deploy_user"
chk "the retry records the account on a line of its own" \
  1 "$(grep -cxF collavre_a "$sd/deploy_users")"

printf 'collavre_a\n' > "$sd/deploy_user"
printf 'collavre_b docker sudo\n' >> "$sd/groups"
revoke_prior_deploy_user collavre_b "$sd/deploy_user" "$sd/deploy_users" >/dev/null 2>&1
chk "and the rotation strips it" 0 "$(grep -c '^collavre_a ' "$sd/groups")"
# The control in the other direction. A fragment names nobody and grants
# nothing, so it must *not* be kept queued for a retry that can never succeed —
# it leaves by the same id -u path, which is the right answer for it.
chk "the fragment is not retried forever" 0 "$(grep -c '^collavre_$' "$sd/deploy_users")"
chk "and the current user stays queued for its own successor" \
  1 "$(grep -cxF collavre_b "$sd/deploy_users")"
unset -f id revoke_deploy_user_access
rm -rf "$sd"

echo "126. a deploy account that cannot run a command is refused"
# refuse_root_deploy_user states this invariant and tests only UID 0: its own
# message is "'$user' could never log in, while the summary would still print
# KAMAL_SSH_USER", which is true word for word of /usr/sbin/nologin. Measured
# against 6125e4ee, 'nobody' and 'daemon' both PROCEED.
fakebin=$(mktemp -d)
printf '#!/bin/sh\necho "This account is currently not available."\nexit 1\n' \
  > "$fakebin/nologin"
printf '#!/bin/sh\nexit 1\n' > "$fakebin/false"
chmod +x "$fakebin/nologin" "$fakebin/false"
# shellcheck disable=SC2329  # called by refuse_nologin_deploy_user
shell_of() {
  case "$1" in
    nobody) echo "$fakebin/nologin" ;; svc) echo "$fakebin/false" ;;
    ghost) echo "" ;; gone) echo /opt/removed-shell ;; *) echo /bin/sh ;;
  esac
}
# shellcheck disable=SC2329
getent() { printf '%s:x:1000:1000::/home/%s:%s\n' "$2" "$2" "$(shell_of "$2")"; }
# shellcheck disable=SC2329
id() { [ "$2" = brandnew ] && return 1; echo 1000; }
# The guard's second probe runs the shell *as the account*, and none of these
# accounts exist on the machine running the suite. Stubbed rather than skipped,
# because the accounts that do exist here would answer for the wrong reason: a
# real `su` to a name with no passwd entry fails, which would read as the
# refusal this case is testing for. 'rootonly' is the account whose shell root
# can execute and the account cannot — case 137.
# shellcheck disable=SC2329
runuser() { [ "$2" = rootonly ] && return 1; shift 3; "$@"; }
for u in nobody svc gone ghost; do
  out="$( (refuse_nologin_deploy_user "$u") 2>&1 )"
  chk "'$u' is refused" 1 "$?"
  case "$out" in
    *"Nothing has been changed"*) echo "  ok   '$u': and says nothing was changed" ;;
    *) echo "  FAIL '$u': did not say the host is unchanged: $out"; fail=1 ;;
  esac
done
out="$( (refuse_nologin_deploy_user nobody) 2>&1 )"
case "$out" in
  *KAMAL_SSH_USER*usermod*) echo "  ok   names both the symptom and the remedy" ;;
  *) echo "  FAIL does not name KAMAL_SSH_USER and usermod: $out"; fail=1 ;;
esac
# The controls, and they are the ones that matter: this guard runs on every
# invocation before anything is installed, so a false positive refuses every
# run — a worse defect than the one being fixed. Same shape as 123a.
refuse_nologin_deploy_user collavre
chk "an ordinary account proceeds"              0 "$?"
refuse_nologin_deploy_user brandnew
chk "an account that does not exist yet proceeds" 0 "$?"
chk "the guard runs beside the UID 0 one, before anything is installed" \
  1 "$(grep -c '^refuse_nologin_deploy_user "\$APP_SSH_USER"' "$SRC")"

echo "137. a shell only root can execute is refused too"
# The probe above runs as root, and root can execute files the deploy account
# cannot — a custom login shell installed mode-0700 root:root is the case.
# Measured on a real Linux host against b3506940:
#
#   shell            /usr/local/bin/rootonly-sh  (700 root:root)
#   [ -x ] as root   yes          probe as root     PASSES
#   probe as account REFUSES      what sshd does    "Permission denied"
#
# So provisioning gave that account docker and passwordless sudo, published
# KAMAL_SSH_USER, and every remote command failed.
out="$( (refuse_nologin_deploy_user rootonly) 2>&1 )"
chk "an account that cannot execute its own login shell is refused" 1 "$?"
case "$out" in
  *"as root but 'rootonly' cannot"*"Nothing has been changed"*)
    echo "  ok   and says which side of the switch failed" ;;
  *) echo "  FAIL does not distinguish root from the account: $out"; fail=1 ;;
esac
# The control in the other direction, and it is the one that decides whether
# this fix can ship: the ordinary account above still proceeds through the same
# probe. Measured on the real host as well — an account whose password is locked
# (`adduser --disabled-password`, which is every key-only deploy account and the
# one this script creates), one with no home directory, and one whose home it
# cannot read all pass. Only the shell it may not execute refuses.
refuse_nologin_deploy_user collavre
chk "and an ordinary account still proceeds through the same probe" 0 "$?"
# Source-level, because the harness stubs `runuser` and would go on passing if
# the call were removed: the probe has to be the account's, not root's.
chk "the second probe switches to the account" \
  1 "$(grep -c 'runuser -u "\$user" -- "\$shell" -c true' "$SRC")"
chk "and falls back to su rather than refusing a host without runuser" \
  1 "$(grep -c 'su -s "\$shell" -c true "\$user"' "$SRC")"
unset -f getent id shell_of runuser
rm -rf "$fakebin"

echo "127. the backup executable is staged and validated, never truncated live"
# The generated file is *executable*, which makes truncation quieter than it is
# for a config file: a stump is not a file that fails to load, it is a shorter
# program that runs. Of the 1233 truncation points of the generated script, 624
# parse and 153 exit 0 without ever reaching pg_dump — and those 153 are the
# first 310 bytes, so an early interruption lands there. `cat >` leaves the mode
# alone and `chmod 0755` was the next statement, so on a re-converge the stump
# stays executable while the timer stays enabled: green nightly runs, no dumps.
bd=$(mktemp -d)
seed_backup() {
  printf '#!/usr/bin/env bash\n# PREVIOUS GOOD BACKUP\nexit 7\n' > "$bd/collavre-pg-backup"
  chmod 0755 "$bd/collavre-pg-backup"
}
run_backup_section() {
  awk '/^BACKUP_TMP="\$\(mktemp/{p=1} p{print} /^mv -f "\$BACKUP_TMP"/{exit}' "$SRC" \
    | sed "s#/usr/local/bin/collavre-pg-backup#\$BIN/collavre-pg-backup#g" > "$bd/sect.sh"
  { printf '%s\n' 'set -euo pipefail' \
      'die() { printf "DIE: %s\n" "$*"; exit 1; }' \
      'BIN="$1"; DB_NAME=collavre_production; BACKUP_RETENTION_DAYS=14' \
      'BACKUP_S3_URI=""; DB_PORT=5432' \
      'mktemp() { command mktemp "${1/\/usr\/local\/bin/$BIN}"; }'
    [ -n "${1:-}" ] && printf '%s\n' "$1"
    cat "$bd/sect.sh"
  } > "$bd/run.sh"
  bash "$bd/run.sh" "$bd" 2>&1
}
seed_backup
run_backup_section >/dev/null
chk "a clean run installs the whole script" \
  1 "$(grep -c 'pg_dump' "$bd/collavre-pg-backup")"
chk "and it is executable"          755 "$(file_mode "$bd/collavre-pg-backup")"
# Injected, not raced: a write that stops partway is the modelled failure and a
# kill loses to a fast local write, as case 4a records.
seed_backup
out=$(run_backup_section 'cat() { head -c 200; return 1; }')
chk "a write cut short refuses"     1 "$(printf '%s' "$out" | grep -c '^DIE:')"
chk "and the previous backup script is still the live one" \
  1 "$(grep -c 'PREVIOUS GOOD BACKUP' "$bd/collavre-pg-backup")"
chk "and no staging file is left behind" \
  0 "$(find "$bd" -name 'collavre-pg-backup.*' | wc -l | tr -d ' ')"
seed_backup
# The invalidity is injected into the generated text rather than smuggled in
# through a configured value. It used to be the latter — a DB_NAME closing the
# quote the template opened — and case 133 took that route away: the three
# configured values are serialized with %q now, so no value can make the file
# unparseable. That is the fix working, not this assertion becoming true; but a
# fixture whose premise its own codebase has made unreachable asserts nothing,
# which is what it did here (`expected [1] got [0]`) before this rewrite.
#
# What the check is still for: truncation, which reaches this from the other
# side, and the next value interpolated into a generated program by someone who
# does not know about %q. Both produce exactly this — a staged file that is not
# a whole script — so that is what the fixture produces directly.
#
# The injection goes through `cat`, which both the heredoc form and the current
# one use, so the fixture reaches the guard the same way whichever way the file
# is generated. An injection that only lands on the current spelling would read
# as a regression against every earlier revision while measuring nothing.
out=$(run_backup_section 'cat() { command cat "$@"; command printf "if [\n"; }')
chk "a generated script that is not valid shell refuses" \
  1 "$(printf '%s' "$out" | grep -c '^DIE:')"
chk "and the previous backup script survives that too" \
  1 "$(grep -c 'PREVIOUS GOOD BACKUP' "$bd/collavre-pg-backup")"
rm -rf "$bd"
chk "the live backup path is not written by redirection" \
  0 "$(grep -c '^cat > /usr/local/bin/collavre-pg-backup' "$SRC")"

echo "128. a database-name probe that cannot answer is refused, not read as 'it exists'"
# The third instance of the shape recorded at role_owns_app_objects, and the
# last `[ "$(psql ...)" = x ] || return 0` in this file. It compares *output*,
# so a psql that could not answer yields an empty string — which is not "0", so
# the `|| return 0` retires the guard on the one reading it has no evidence for.
#
# Proceeding here is not a deferred refusal. The guard sits ahead of the
# creation SQL, so a run where the cluster comes back a moment later creates the
# typo'd database empty, advances both markers onto it, and points DATABASE_URL
# and the nightly pg_dump at it while the app's data stays in the database
# nothing now names.
dn6=$(mktemp -d); printf 'collavre_user\n' > "$dn6/db_user"
PROBE_FAILS=0
# shellcheck disable=SC2329  # called by refuse_db_name_change
psql_as_postgres() {
  [ "$PROBE_FAILS" = 0 ] || return 1
  # Answers about the name actually asked for, so the control below is a real
  # "this database is there" and not the refusal path wearing its clothes.
  case "$2" in
    *"count(*)"*"'collavre_production'"*) echo 1 ;;
    *"count(*)"*) echo 0 ;;
    *) echo "collavre_production" ;;
  esac
}
PROBE_FAILS=1
out="$( (refuse_db_name_change collavre_typo "$dn6") 2>&1 )"
chk "an unanswerable probe is refused" 1 "$?"
case "$out" in
  *"would not say whether"*"Nothing has been changed"*)
    echo "  ok   and it names the cluster, not the name" ;;
  *) echo "  FAIL passed or was unhelpful: $out"; fail=1 ;;
esac
# The control in the other direction, and the one no negative control catches:
# this guard runs on every re-run, so a probe answered "the database is there"
# must still proceed. A guard that refused here would stop every convergence.
PROBE_FAILS=0
( refuse_db_name_change collavre_production "$dn6" ) >/dev/null 2>&1
chk "an answered probe still proceeds" 0 "$?"
unset -f psql_as_postgres
rm -rf "$dn6"

echo "129. daemon.json is replaced by rename, not by truncating the live file"
# The validation was already right and the install was not: jq checked the
# staging file and `cat "$tmp" > "$file"` then truncated the live one to copy it
# in, so the file that was checked is not the file that ends up installed.
# Nothing notices, either — the caller only restarts Docker on a run that
# changed the file, so the running daemon keeps the config it read at boot and
# the host stays healthy until a reboot it cannot come back from.
#
# Injected rather than raced, as case 4a records: a kill loses to a fast local
# write, and a flaky control is worse than none.
dj=$(mktemp -d)
seed_daemon() {
  printf '{"insecure-registries":["10.0.0.1:5000"],"log-driver":"json-file"}\n' \
    > "$dj/daemon.json"
}
seed_daemon
( DAEMON_JSON_CHANGED=0; ensure_docker_log_caps "$dj/daemon.json" ) >/dev/null 2>&1
chk "a clean run caps the logs"      '"10m"' \
  "$(jq -c '."log-opts"."max-size"' "$dj/daemon.json")"
chk "and keeps the operator's keys"  1 "$(jq -e 'has("insecure-registries")' "$dj/daemon.json" >/dev/null && echo 1 || echo 0)"
seed_daemon
( DAEMON_JSON_CHANGED=0
  # shellcheck disable=SC2329  # shadows the copy the previous form installed with
  cat() { command cat "$@" | head -c 20; return 1; }
  ensure_docker_log_caps "$dj/daemon.json" ) >/dev/null 2>&1
chk "a copy that fails leaves valid JSON" 1 \
  "$(jq empty "$dj/daemon.json" >/dev/null 2>&1 && echo 1 || echo 0)"
chk "and the operator's registry survives" 1 \
  "$(grep -c insecure-registries "$dj/daemon.json")"
chk "and no staging file is left behind" 0 \
  "$(find "$dj" -name 'daemon.json.collavre.*' | wc -l | tr -d ' ')"
# rename(2) does not follow symlinks and the copy did: without resolution this
# fix would replace a symlinked /etc/docker/daemon.json with a regular file and
# leave the real path — the one dockerd reads — holding what it held before.
# A control against the obvious implementation of the remedy, not against the
# reviewed revision, which passes it.
mkdir -p "$dj/real"; printf '{"log-driver":"json-file"}\n' > "$dj/real/daemon.json"
ln -s real/daemon.json "$dj/link.json"
( DAEMON_JSON_CHANGED=0; ensure_docker_log_caps "$dj/link.json" ) >/dev/null 2>&1
chk "a symlinked daemon.json is still a symlink" 1 "$([ -L "$dj/link.json" ] && echo 1 || echo 0)"
chk "and the real file got the caps" '"10m"' \
  "$(jq -c '."log-opts"."max-size"' "$dj/real/daemon.json")"
rm -rf "$dj"

echo "130. stage_beside carries the target's identity, and invents one when there is none"
# The primitive the three staged installs share. Two properties, and the second
# is the one that would have shipped a broken cluster: mktemp creates 0600, so a
# first-run 10-collavre.conf installed straight from a staging file would be
# unreadable by the postgres user that has to read it — the fix for a truncated
# config would stop the cluster outright. `cat >` under root's umask produced
# 0644 and that is what a target-less stage has to reproduce.
sb=$(mktemp -d)
printf 'old\n' > "$sb/target"; chmod 0640 "$sb/target"
t="$(stage_beside "$sb/target")"
chk "staged in the target's own directory" "$sb" "$(dirname "$t")"
chk "carrying the target's mode"           640 "$(file_mode "$t")"
chk "and the live file is untouched"       old "$(cat "$sb/target")"
rm -f "$t"
t="$(stage_beside "$sb/absent")"
chk "a target that does not exist yet gets the default"  644 "$(file_mode "$t")"
chk "and an explicit mode is honoured"                   755 \
  "$(u="$(stage_beside "$sb/absent2" 0755)"; file_mode "$u")"
rm -f "$t"
mktemp() { return 1; }
stage_beside "$sb/target" >/dev/null 2>&1
chk "nowhere to stage reports 1, not 2"    1 "$?"
unset -f mktemp
rm -rf "$sb"
# Source-level control. The helpers are new, so the assertions above cannot be
# run against the reviewed revision — the suite stops at its own extraction
# check. What can be asserted there is that no generated file is still written
# through its live path.
chk "the PostgreSQL config is not written by redirection" \
  0 "$(grep -c '^cat > "\$PG_CONF_DIR/conf.d/10-collavre.conf"' "$SRC")"
chk "it is staged and renamed instead" \
  1 "$(grep -c '^mv -f "\$PG_CONF_TMP" "\$PG_CONF_REAL"' "$SRC")"
# Anchored past the comment that quotes the old form: the first spelling of this
# matched the explanation of the fix and would have gone on passing after a
# revert, which is the assertion testing the prose instead of the code.
chk "and daemon.json is not installed by copy" \
  0 "$(grep -cE '^[[:space:]]*cat "\$tmp" > "\$file"' "$SRC")"

echo "131. a torn append to authorized_keys does not glue the successor to it"
# The last `>>` in this script that was not a queue, and the one where a
# fragment costs more than a forgotten record. install_authorized_keys guards
# its append with `grep -qxF`, which does not match a fragment, so a retry lands
# the whole key on the end of one — and revoke_prior_ssh_key opens with
# "never withdraw before the successor is in place", tested by that same exact
# match. The successor is not an exact line, so the rotation withdraws nothing
# and reports success, leaving the predecessor authorized on an account with
# docker and passwordless sudo.
#
# The fragment is injected, as in case 4a and 125: ENOSPC and RLIMIT_FSIZE both
# produce one and neither is reachable here, and the partial write is not the
# claim — what the retry does with it is.
sd=$(mktemp -d); ak="$sd/authorized_keys"
KA="ssh-rsa AAAAB3NzaC1yc2EAAAA_KEY_A_AAAAAAAAAAAAAAAAAAAAAAAA deploy@a"
KB="ssh-rsa AAAAB3NzaC1yc2EAAAA_KEY_B_BBBBBBBBBBBBBBBBBBBBBBBB deploy@b"
SSH_PUBLIC_KEY="$KA"
record_ssh_key_grant "$KA" "$sd/keys" "$sd/key" >/dev/null
install_authorized_keys "$ak"
printf '%s\n' "$KA" > "$sd/key"
chk "the predecessor is authorized to begin with" 1 "$(grep -cxF "$KA" "$ak")"

SSH_PUBLIC_KEY="$KB"
record_ssh_key_grant "$KB" "$sd/keys" "$sd/key" >/dev/null
printf '%s' "${KB:0:34}" >> "$ak"          # <- the torn append; the run dies here
# the retry
install_authorized_keys "$ak"
chk "the retry gives the successor a whole line of its own" 1 "$(grep -cxF "$KB" "$ak")"
chk "and does not extend the fragment" 0 "$(grep -c "^${KB:0:34}${KB:0:6}" "$ak")"
revoke_prior_ssh_key "$ak" "$sd/key" "$sd/keys" >/dev/null 2>&1
chk "so the rotation completes on that retry, not a run later" 0 "$(grep -cxF "$KA" "$ak")"
# The control in the other direction, and the reason this is a rewrite rather
# than a delete-and-rewrite: a key the operator put there by hand is not one of
# ours to move, and a fragment authorizes nobody so it is left to
# dedupe_authorized_keys rather than guessed at.
chk "a key added by hand is untouched" 1 \
  "$(printf 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5_HANDKEY operator\n' >> "$ak"
     install_authorized_keys "$ak"; grep -c _HANDKEY "$ak")"
# A staged file that cannot be completed must not be installed: the live
# authorized_keys is the only way into the host.
before="$(cat "$ak")"
# shellcheck disable=SC2329  # shadows the staging write for this case only
mktemp() { return 1; }
SSH_PUBLIC_KEY="ssh-rsa AAAAB3NzaC1yc2EAAAA_KEY_C_CCCCCCCCCCCCCCCCCCCC deploy@c"
install_authorized_keys "$ak" >/dev/null 2>&1
chk "a staging failure reports it" 1 "$?"
unset -f mktemp
chk "and the live authorized_keys is untouched" "$before" "$(cat "$ak")"
chk "the key is not written by redirection" \
  0 "$(grep -cE '^[[:space:]]*printf .%s.n. "\$SSH_PUBLIC_KEY" >> "\$auth_keys"' "$SRC")"
rm -rf "$sd"

echo "132. the ufw rule marker is replaced, and an empty one is not passed over"
# `> "$state"` truncates at open, and the read at the top of ensure_ufw_rule
# branches on `[ -n "$prior" ]` — so an empty marker is not a degraded record
# but no record, the withdrawal block is skipped, and the rule in force when the
# write was cut stays in force with nothing naming it. Measured on the extracted
# function with the marker emptied after the first converge and the subnet then
# changed twice: the 172.17.0.0/16 rule survives both, permanently, because
# every later run withdraws what the marker names and the marker has moved past
# it.
sd=$(mktemp -d); RULES="$sd/rules"; : > "$RULES"
# shellcheck disable=SC2329  # called by ensure_ufw_rule
ufw() { case "$1" in
  delete) shift; grep -vxF "$*" "$RULES" > "$RULES.n"; mv "$RULES.n" "$RULES" ;;
  *) grep -qxF "$*" "$RULES" || printf '%s\n' "$*" >> "$RULES" ;; esac; }
R1="allow from 172.17.0.0/16 to any port 5432 proto tcp"
R2="allow from 10.0.8.0/24 to any port 5432 proto tcp"
ensure_ufw_rule postgres "$R1" "$sd/m" >/dev/null
chk "the marker records the rule" "$R1" "$(cat "$sd/m")"
chk "and is written whole, not by redirection" \
  0 "$(grep -cE "^[[:space:]]*printf '%s..n' \"\\\$rule\" > \"\\\$state\"" "$SRC")"
# The read side, which the write side cannot reach: a host provisioned by an
# earlier revision may already carry an emptied marker, and there is no second
# record to fall back to — `ufw status` prints a display form `ufw delete` does
# not accept, which is why this marker exists. So it is said rather than passed.
: > "$sd/m"
# Through LOGGED rather than a captured subshell, because ensure_ufw_rule has
# to run in *this* shell for the assertions below to see what it did — and
# cleared explicitly rather than assumed empty, since it accumulates across
# cases and the last one to set it is whichever ran before this. Same leak as
# the one recorded at 49.
log() { LOGGED="$LOGGED $*"; }
LOGGED=""
ensure_ufw_rule postgres "$R2" "$sd/m"
case "$LOGGED" in
  *"exists but is empty"*"ufw status numbered"*)
    echo "  ok   an empty marker is reported, with what to look at" ;;
  *) echo "  FAIL an empty marker passed silently: $LOGGED"; fail=1 ;;
esac
chk "the stranded rule really is still in force" 1 "$(grep -cxF "$R1" "$RULES")"
# The control in the other direction: an *absent* marker is a first converge and
# must say nothing, since this runs on every convergence of every rule.
rm -f "$sd/m"
LOGGED=""
ensure_ufw_rule postgres "$R2" "$sd/m"
case "$LOGGED" in
  *"exists but is empty"*) echo "  FAIL a first converge was warned about"; fail=1 ;;
  *) echo "  ok   a first converge says nothing" ;;
esac
unset -f ufw
rm -rf "$sd"

echo "133. configured values reach the backup script as data, not as source"
# The generated file is a *program*, so a value spliced into it verbatim is not
# a string in that program — it is source text the nightly unit evaluates as
# root. A legitimate S3 key prefix can carry either shape, and `bash -n` accepts
# both: they are perfectly good shell, which is exactly the problem. The
# validation below asks whether the file is a program, not whether it is the
# intended one, so it cannot be what closes this.
#
# Driven through the real generation region rather than a reduction of it: the
# whole claim is about what that region writes, so a harness that reimplements
# it would pass against every revision including the one being fixed.
bd=$(mktemp -d)
bk=$(mktemp -d)
gen_backup() {
  seed_backup
  run_backup_section "BACKUP_S3_URI='$1'" >/dev/null
}
# What the nightly unit does with the generated file, reduced to the part in
# question: it runs it, under the `set -u` the generated file sets for itself,
# so every assignment in it is evaluated. As root.
upload_prefix() {
  ( set -u
    eval "$(grep -E '^S3_URI=' "$bd/collavre-pg-backup")"
    printf 'UPLOAD-TO=%s\n' "$S3_URI" ) 2>&1
}
# Command substitution in a configured prefix must survive as characters.
gen_backup 's3://b/$(touch '"$bk"'/RAN; echo pwned)/db'
out="$(upload_prefix)"
chk "a substitution in the S3 prefix is not executed" 0 \
  "$([ -f "$bk/RAN" ] && echo 1 || echo 0)"
chk "and reaches the upload as characters" \
  'UPLOAD-TO=s3://b/$(touch '"$bk"'/RAN; echo pwned)/db' "$out"
# A literal $name is the quieter half: under the generated script's own `set -u`
# the spliced form dies with `unbound variable`, so the nightly backup stops
# and the failure is nowhere near the value that caused it.
gen_backup 's3://b/$archive/db'
out2="$(upload_prefix)"
chk "and is uploaded to the prefix as configured" \
  'UPLOAD-TO=s3://b/$archive/db' "$out2"
# The controls in the other direction, and the ones that constrain the fix:
# every real host has one of these two, so a change in either is a change to
# where every existing backup goes.
gen_backup 's3://collavre-backups/prod'
chk "an ordinary prefix is unchanged" 'UPLOAD-TO=s3://collavre-backups/prod' \
  "$(upload_prefix)"
gen_backup ''
chk "and the unset default stays empty" 'UPLOAD-TO=' "$(upload_prefix)"
rm -rf "$bk" "$bd"
# Source-level control. The assertions above are about the shape of the
# generation step, so this is what fails against a revert: the heredoc spliced
# all three in, and %q is what replaced it.
chk "no configured value is spliced into the generated script" 0 \
  "$(grep -cE '^(DB_NAME="\$DB_NAME"|RETENTION_DAYS=\$BACKUP_RETENTION_DAYS|S3_URI="\$BACKUP_S3_URI")$' "$SRC")"
chk "they are serialized with %q instead" 1 \
  "$(grep -c "printf 'DB_NAME=%q" "$SRC")"


# log() is redefined per region above and the nearest one accumulates into
# $LOGGED rather than printing. These three cases assert on what the run *says*,
# so it has to print — without this the message assertions below pass on an
# empty capture, which is the failure mode a negative control exists to catch.
log() { echo "[log] $*"; }

echo "134. a create of daemon.json that is cut short never reaches the live path"
# The rewrite path was staged earlier on this branch; the create path below it
# was not, and it is the one a first-time provision takes. `cat > "$file"` opens
# the live path with O_TRUNC, so a write that fails leaves a partial daemon.json
# that no later run repairs — the retry finds the file present and takes the
# rewrite path, where every branch declines to touch it.
dj=$(mktemp -d)
# The staged write is cut short by shadowing `cat` for one call, injected rather
# than raced: a kill loses to a fast local write, and a flaky control is worse
# than none.
# The shortened write reports success, which is the case that matters and the
# one this fixture got wrong first: `head -c 0` errors on BSD and succeeds on
# GNU, so the case passed on macOS because the *write* failed rather than
# because the check caught a short file, and CI failed it on Linux — where the
# 0-byte staging file validated (jq accepts an empty document) and was renamed
# into place. `dd` is used instead so the write succeeds on both, which is what
# a disk that fills after the file is created actually does.
torn_create() {  # $1 = bytes of the write that survive
  ( KEEP=$1
    cat() { dd bs=1 count="$KEEP" 2>/dev/null; return 0; }
    ensure_docker_log_caps "$dj/daemon.json" >/dev/null 2>&1 )
}
torn_create 0
chk "a torn create leaves no live daemon.json" 0 \
  "$([ -e "$dj/daemon.json" ] && echo 1 || echo 0)"
chk "and no staging file behind either" 0 \
  "$(find "$dj" -name '*.collavre.*' | wc -l | tr -d ' ')"
# The retry is the assertion that matters: against the old form this is where
# the run gives up for good.
ensure_docker_log_caps "$dj/daemon.json" >/dev/null 2>&1
chk "so the next run creates it whole" '10m' \
  "$(jq -r '."log-opts"."max-size" // "NONE"' "$dj/daemon.json" 2>/dev/null || echo UNPARSEABLE)"
# 0644, not mktemp's 0600. A daemon.json dockerd cannot read is the same outage
# by another route, which is why stage_beside refuses rather than narrowing it.
chk "at the mode the old form produced" 644 "$(file_mode "$dj/daemon.json")"
# The read side, for hosts already carrying the damage: an empty daemon.json is
# the one size the rewrite path cannot see, since `jq empty` exits 0 on it and
# the driver query returns "" rather than the default — so the old form reported
# an operator who chose another driver over a host with uncapped logs.
: > "$dj/empty.json"
ej="$(ensure_docker_log_caps "$dj/empty.json" 2>&1)"
chk "an empty daemon.json is not read as a driver choice" 0 \
  "$(grep -c 'rotates on its own' <<<"$ej")"
chk "it is named as an interrupted create" 1 \
  "$(grep -c 'exists but is empty' <<<"$ej")"
chk "and the caps are put in" '10m' \
  "$(jq -r '."log-opts"."max-size" // "NONE"' "$dj/empty.json" 2>/dev/null || echo UNPARSEABLE)"
# The control the empty case must not widen into: a partial file may hold half
# of an operator's configuration, nothing tells it apart from one this script
# tore, and it is still left exactly as it is.
printf '{"insecure-regist' > "$dj/partial.json"
pj="$(ensure_docker_log_caps "$dj/partial.json" 2>&1)"
chk "a partial daemon.json is still left alone" 1 \
  "$(grep -c 'not valid JSON' <<<"$pj")"
chk "and not rewritten" '{"insecure-regist' "$(cat "$dj/partial.json")"
rm -rf "$dj"
chk "the create is not written by redirection" 0 \
  "$(grep -cE '^    cat > "\$file" <<' "$SRC")"

echo "135. no key to install is a refusal, not a completed run"
# The contract above install_authorized_keys says non-zero aborts the run. A
# `for` loop whose every iteration took the `continue` completes with status 0,
# so the one path where nothing could be installed was the one reporting
# success — and the steps after it put the account in docker and sudoers.
kd=$(mktemp -d); mkdir -p "$kd/home"
: > "$kd/authorized_keys"
( SSH_PUBLIC_KEY=''; install_authorized_keys "$kd/authorized_keys" "$kd/home" ) >/dev/null 2>&1
chk "nothing to install reports failure" 1 "$?"
# The control in the other direction, and the one that constrains the fix: this
# runs on every convergence, so refusing a host whose cloud user was renamed
# away but whose authorized_keys is already populated would take down every
# re-run on a host that works.
printf 'ssh-ed25519 AAAAOPS ops@laptop\n' > "$kd/authorized_keys"
kout=$( SSH_PUBLIC_KEY=''; install_authorized_keys "$kd/authorized_keys" "$kd/home" 2>&1 )
chk "an already-populated file is left alone" 0 "$?"
chk "and the run says why it did nothing" 1 \
  "$(grep -c 'already authorizes someone' <<<"$kout")"
chk "the key it had is untouched" 1 "$(grep -c 'AAAAOPS' "$kd/authorized_keys")"
# And the ordinary path is unchanged.
mkdir -p "$kd/home/ubuntu/.ssh"
printf 'ssh-ed25519 AAAACLOUD cloud\n' > "$kd/home/ubuntu/.ssh/authorized_keys"
: > "$kd/authorized_keys"
( SSH_PUBLIC_KEY=''; install_authorized_keys "$kd/authorized_keys" "$kd/home" ) >/dev/null 2>&1
chk "a cloud user's keys are still copied" 0 "$?"
chk "and land in the file" 1 "$(grep -c 'AAAACLOUD' "$kd/authorized_keys")"
rm -rf "$kd"
# Source-level: the call site acts on the status rather than leaving it to
# errexit, which would abort with nothing said about the account holding sudo.
chk "the call site names the account it aborts over" 1 \
  "$(grep -c 'no SSH key could be installed' "$SRC")"

echo "136. the Docker plugins are installed on a host that already has docker"
# The plugin install sat inside `if ! command -v docker`, unreachable on the one
# host that needs it named separately: the documented by-hand run on an existing
# instance carrying Ubuntu's docker.io. The runbook promises buildx for the
# remote builder, so the first `builder.remote` Kamal build fails on a host this
# script reported as converged.
docker_step() {  # DOCKER_PRESENT / BUILDX_OK / COMPOSE_OK are read from the env
  ( set +u
    log(){ printf 'LOG: %s\n' "$*"; }
    install(){ :; }; apt_get(){ :; }
    # shellcheck disable=SC2329  # called by the extracted Docker step
    install_managed_config(){ :; }; install_downloaded_file(){ :; }
    dpkg(){ echo amd64; }; VERSION_CODENAME=noble
    apt_install(){ printf 'INSTALL:%s\n' "$*"; }
    command(){
      if [ "${1:-}" = -v ] && [ "${2:-}" = docker ]; then
        [ "$DOCKER_PRESENT" = yes ]; return $?
      fi
      builtin command "$@"
    }
    docker(){
      [ "${1:-}" = buildx ]  && { [ "$BUILDX_OK" = yes ];  return $?; }
      [ "${1:-}" = compose ] && { [ "$COMPOSE_OK" = yes ]; return $?; }
      return 0
    }
    . "$td/step.sh" 2>/dev/null ) | grep '^INSTALL:' | sed 's/^INSTALL://'
}
td=$(mktemp -d)
# The step is top-level code rather than a function, so it is taken from $SRC by
# its banner and the comment that follows it rather than through the extraction
# above. An empty extraction would make every row read "installs nothing", which
# is a real answer for one of them — so the extraction is asserted first.
awk '/^log "4\/9 Docker CE"/{p=1} /^# Cap container logs/{exit} p{print}' "$SRC" > "$td/step.sh"
chk "the Docker step was extracted" 1 "$(grep -c 'apt_install' "$td/step.sh")"
chk "a fresh host installs the whole set" \
  'docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin' \
  "$(DOCKER_PRESENT=no BUILDX_OK=no COMPOSE_OK=no docker_step)"
# The control that constrains the fix: this runs on every convergence, so a
# converged host must come out of it with nothing to do.
chk "a host with both plugins installs nothing" '' \
  "$(DOCKER_PRESENT=yes BUILDX_OK=yes COMPOSE_OK=yes docker_step)"
chk "docker.io without buildx gets buildx" 'docker-buildx-plugin' \
  "$(DOCKER_PRESENT=yes BUILDX_OK=no COMPOSE_OK=yes docker_step)"
chk "and without either gets both" 'docker-buildx-plugin docker-compose-plugin' \
  "$(DOCKER_PRESENT=yes BUILDX_OK=no COMPOSE_OK=no docker_step)"
rm -rf "$td"
chk "the plugins are not gated on the docker binary" 0 \
  "$(grep -cE 'apt_install docker-ce docker-ce-cli containerd.io' "$SRC")"

echo "138. a cluster layout that cannot be read is refused, not read as empty"
# `pg_lsclusters -h` used to be expanded straight into the here-document feeding
# the loop, where a command substitution's status is discarded — and a `while`
# whose body never runs completes with status 0. So a layout query that failed
# gave the guard its one PROCEED answer. Measured against b3506940:
#
#   stub                                     reviewed   fixed
#   14/main on 5432, exit 0                  refuses    refuses
#   exits 1, nothing on stdout               PROCEEDS   refuses
#   exits 1 after printing only 12/main      PROCEEDS   refuses
#   exits 0, nothing on stdout (fresh host)  proceeds   proceeds
mk_failing_lsclusters() {   # <name> <stdout> <status>
  local bin="$CLUSTER_BIN_DIR/$1"
  { echo '#!/bin/sh'; [ -z "$2" ] || echo "echo '$2'"; echo "exit $3"; } > "$bin"
  chmod +x "$bin"
}
PG_MAJOR=17
DB_PORT=5432
mk_failing_lsclusters pg_ls_unreadable '' 1
out="$( (ensure_cluster_on_default_port pg_ls_unreadable) 2>&1 )"
chk "a layout query that fails silently is refused" 1 "$?"
case "$out" in
  *"cannot tell which PostgreSQL clusters exist"*"Nothing has been changed"*)
    echo "  ok   and says why, rather than naming a version it never read" ;;
  *) echo "  FAIL unhelpful message: $out"; fail=1 ;;
esac
# The sharper row: the guard did see clusters, just not the one holding the
# port. A count of rows cannot tell this from a host that really has only that
# cluster — the status can.
mk_failing_lsclusters pg_ls_cut '12  main    5434 online postgres /var/lib/postgresql/12/main /var/log/x' 1
out="$( (ensure_cluster_on_default_port pg_ls_cut) 2>&1 )"
chk "and so is one that fails after printing some of the clusters" 1 "$?"
# The control, and it is the reason the fix is on the status and not on the
# output: postgresql-common is installed here before any cluster exists, so
# `pg_lsclusters -h` on a fresh host is legitimately silent and successful.
# Refusing emptiness would refuse every first run.
mk_failing_lsclusters pg_ls_nocluster '' 0
out="$( (ensure_cluster_on_default_port pg_ls_nocluster) 2>&1 )"
chk "a fresh host with no cluster yet proceeds" 0 "$?"
chk "and says nothing"                          "" "$out"
chk "the layout is no longer expanded inside the here-document" 0 \
  "$(grep -c '^\$("\$lsclusters" -h 2>/dev/null)$' "$SRC")"

echo "139. the recovery restore hands the objects to the role DATABASE_URL names"
# Without --no-owner the archive's ownership is replayed, and a dump taken
# before a supported DB_USER rotation names the previous role. Measured on a
# real cluster, restoring such a dump into a rotated database:
#
#                                   owner after    the app role's own SELECT
#   --clean --if-exists             collavre_old   ERROR: permission denied
#   + --no-owner --role=<app role>  collavre_new   1 row
#
# pg_restore exited 0 in both, so the block reports a completed recovery over a
# database the app cannot read. The import recipe earlier in this document
# already pairs the two flags; this block is the one that had only half of it.
LIVE=0 KILLED=0 FAIL_RESTORE='' run_restore
case "$R_RESTORE_ARGS" in
  *--no-owner*--role=collavre_user*)
    echo "  ok   the restore runs with --no-owner and --role" ;;
  *) echo "  FAIL restore ran as: $R_RESTORE_ARGS"; fail=1 ;;
esac
# The role it hands them to is the one read from the host, not a literal: a
# recovery block that named the default would restore a rotated host into a
# role it stopped using.
APP_ROLE=collavre_rotated LIVE=0 KILLED=0 run_restore
case "$R_RESTORE_ARGS" in
  *--role=collavre_rotated*) echo "  ok   and names the role this host records" ;;
  *) echo "  FAIL did not follow \$app_role: $R_RESTORE_ARGS"; fail=1 ;;
esac
# The control that makes --role safe to use at all: both refusals above answer
# before this line, so an empty or superuser role never reaches the restore.
# Asserted through the block rather than by reading it, since that is the
# guarantee --role is leaning on.
# APP_SUPER='' alongside it, which is what the harness above documents an
# absent role as coming back with. Leaving it at the default 'f' would have the
# stub answer "not a superuser" about a role that is not there — a cluster
# behaviour no cluster has, and the assertion then fails for the fixture's
# reason rather than the block's.
APP_ROLE='' APP_SUPER='' LIVE=0 KILLED=0 run_restore
case "$R_TRACE" in
  *PG_RESTORE_RAN*) echo "  FAIL an empty app_role still reached the restore"; fail=1 ;;
  *) echo "  ok   an empty app_role is refused before the restore" ;;
esac
APP_SUPER=t APP_ROLE=postgres LIVE=0 KILLED=0 run_restore
case "$R_TRACE" in
  *PG_RESTORE_RAN*) echo "  FAIL a superuser app_role still reached the restore"; fail=1 ;;
  *) echo "  ok   and so is a superuser one" ;;
esac
# The recovery for the case --role makes louder: objects owned by a third role
# make the --clean DROPs fail with "must be owner", measured, and the database
# is left untouched rather than half-replaced. The operator needs the way out.
chk "the block says what to do when the drops are refused" 1 \
  "$(grep -c 'must be owner of table' "$DOC")"

echo "140. a DB_USER rotated back to a previous name can log in again"
# reassign_prior_db_role takes LOGIN from the role it replaces, and the CREATE
# that carries LOGIN is skipped for a role that already exists. So a host going
# DB_USER a -> b -> a used to end with an ALTER that set only the password.
# Measured on a real PostgreSQL cluster, the same three runs each time:
#
#   run                shipped                              with LOGIN on the ALTER
#   1  DB_USER=a       connects                             connects
#   2  DB_USER=b       connects, a -> NOLOGIN               same
#   3  DB_USER=a       FATAL: role "a" is not permitted      connects
#                      to log in;  b also NOLOGIN
#
# Every statement succeeds on run 3 — ON_ERROR_STOP has nothing to stop on —
# and it leaves *no* application login on the cluster, since the rotation
# correctly disarms 'b' on the way past.
sqld=$(mktemp -d)
gen_db_sql() {   # <db-user> <password>
  awk '/^SQL_FILE="\$\(mktemp/{p=1} p{print} /^trap - EXIT$/{exit}' "$SRC" > "$sqld/sect.sh"
  # Through the environment rather than spliced into the generated harness:
  # writing a configured value into a program is the defect case 133 is about,
  # and a fixture that does it is the same mistake one level up. And the file is
  # removed first — spliced, a value that closed the assignment killed the run
  # before it generated anything and the assertion read the *previous* call's
  # file, which is a pass or a fail decided by fixture quoting.
  rm -f "$sqld/generated.sql"
  { printf '%s\n' 'set -euo pipefail' \
      'DB_NAME=collavre_production' \
      'chown() { :; }' \
      'runuser() { cp "${!#}" '"$sqld"'/generated.sql; }'
    cat "$sqld/sect.sh"
  } > "$sqld/run.sh"
  DB_USER="$1" DB_PASSWORD="$2" bash "$sqld/run.sh" >/dev/null 2>&1
  cat "$sqld/generated.sql" 2>/dev/null
}
GEN="$(gen_db_sql collavre_user 'pw')"
chk "the ALTER restores LOGIN as well as the password" 1 \
  "$(printf '%s\n' "$GEN" | grep -c '^ALTER ROLE "collavre_user" LOGIN PASSWORD')"
# The control that keeps the fix from being a rewrite of the statement: the
# password is still set by the same ALTER. A separate `ALTER ROLE ... LOGIN`
# would pass the assertion above and leave a run that rotates the password able
# to fail between the two, with the role's password and the recorded one
# disagreeing.
GEN="$(gen_db_sql collavre_user 'pw-not-quoted')"
chk "and still carries the password in the same statement" 1 \
  "$(printf '%s\n' "$GEN" | grep -c "^ALTER ROLE \"collavre_user\" LOGIN PASSWORD 'pw-not-quoted';\$")"
# And the other direction: the CREATE keeps LOGIN too. Dropping it there in
# favour of the ALTER would leave a window on a fresh host between the two
# statements, and this file is read by operators as the record of what the role
# is given.
chk "the CREATE still carries LOGIN for a role that does not exist yet" 1 \
  "$(printf '%s\n' "$GEN" | grep -c "CREATE ROLE %I LOGIN")"
rm -rf "$sqld"

echo "141. a custom DB_PASSWORD containing a quote reaches the role intact"
# This assertion could not be written while the escaping was spelled
# `${DB_PASSWORD//\'/\'\'}`, because that expression does not mean the same
# thing on every bash — measured, same input, same expression:
#
#   bash 5.2.15  (Ubuntu: Lightsail, and this job)              it''s
#   bash 3.2.57  (macOS: what a developer runs this suite on)   it\'\'s
#
# So it was green here and red on a laptop for a reason with nothing to do with
# the statement under test, and case 140 above says as much where it picks an
# unquoted password on purpose. Spelling the doubling through a variable makes
# the two agree, which is what makes the case possible rather than what makes
# it pass — on this runner the previous form was already correct.
#
# It is worth asserting because a custom DB_PASSWORD is supported and
# documented, and because on the revision where the two disagree the failure
# lands after the password has been recorded: measured on a real cluster under
# bash 3.2, psql stops with `invalid command \'x` and the role is left existing
# with NO password while $STATE_DIR/db_password holds one, so the re-run reads
# that same value back and stops in the same place.
#
# These match on `PASSWORD '...'` without the LOGIN that case 140 adds. The two
# fixes landed together and the first draft asserted the whole statement, so
# every row here — including the five controls — went red against a revision
# missing *either* of them, and the case reported the escaping as broken for
# five passwords that contain no quote. A control that fails for the neighbouring
# change's reason is not a control.
sqld=$(mktemp -d)
GEN="$(gen_db_sql collavre_user "pas'wd")"
chk "the quote is doubled for the SQL literal" 1 \
  "$(printf '%s\n' "$GEN" | grep -c "PASSWORD 'pas''wd';\$")"
# The half that says which way it went wrong: a backslash before the quote is
# what the version-dependent form produced, and psql reads it as a meta-command
# rather than as part of the literal.
chk "and not escaped with a backslash" 0 \
  "$(printf '%s\n' "$GEN" | grep -c "PASSWORD 'pas\\\\'")"
# The controls, and they are the ones that matter: every password an existing
# host actually has must come out unchanged. Measured against a live cluster on
# both spellings — generated-alphanumeric, and customs carrying a dollar, a
# double quote, a backslash and a semicolon — all six rc=0 and connecting on
# both; only the quoted row moves. Asserted here on the generated text, since
# this job has no cluster.
for pw in 'aB3xQ9zL7mN2pR5tV8wY1cD4fG6hJ0kM' 'p$aswd$x' 'pas"wd' 'pas\wd' 'pas;wd--x'; do
  GEN="$(gen_db_sql collavre_user "$pw")"
  chk "a password with no quote is passed through unchanged: $pw" 1 \
    "$(printf '%s\n' "$GEN" | grep -cF "PASSWORD '$pw';")"
done
rm -rf "$sqld"

echo "142. a forced-command SSH key is refused before it replaces a working one"
# Measured against a scratch sshd rather than reasoned about, because what is
# claimed is what sshd does with the line and nothing else can answer it. One
# authorized_keys line at a time, the client asking for `echo <marker>`:
#
#   line                             ssh-keygen -l   ssh rc   what actually ran
#   <key>                            parses          0        the client's command
#   from="127.0.0.1" <key>           parses          0        the client's command
#   no-pty,no-agent-forwarding <key> parses          0        the client's command
#   restrict <key>                   parses          0        the client's command
#   restrict,pty <key>               parses          0        the client's command
#   command="/usr/bin/false" <key>   parses          1        nothing
#   command="/usr/bin/true"  <key>   parses          0        nothing
#
# The last row is why this is a refusal and not a warning: every Kamal step
# reports success and none of them runs, on a host provisioning also reported
# as converged. The five rows above it are the controls, and they are the ones
# that constrain the fix — case 119 exists because a shape check strict enough
# to catch a truncated key refuses those, so "refuse a line with options" is
# not available here.
if ! command -v ssh-keygen >/dev/null 2>&1; then
  echo "  SKIP no ssh-keygen here — the neighbouring guard's dependency is missing"
else
  fcd="$(mktemp -d)"
  ssh-keygen -q -t ed25519 -N '' -C 'operator@laptop' -f "$fcd/k" >/dev/null
  FC_KEY="$(cat "$fcd/k.pub")"
  fc_rc=0
  fcguard() {
    ( SSH_PUBLIC_KEY="$1" APP_SSH_USER=collavre
      refuse_forced_command_ssh_key ) >/dev/null 2>&1 && fc_rc=0 || fc_rc=1
  }

  fcguard "command=\"/usr/bin/true\" $FC_KEY"
  chk "a forced command that exits 0 is refused"       1 "$fc_rc"
  fcguard "command=\"/usr/bin/false\" $FC_KEY"
  chk "and one that fails, for the same reason"        1 "$fc_rc"
  # Options are order-free, so the check cannot key on the line starting with
  # `command=`.
  fcguard "no-pty,command=\"/usr/bin/true\" $FC_KEY"
  chk "and one behind another option"                  1 "$fc_rc"
  # sshd matches the option *name* without regard to case, so a case-sensitive
  # test here is a bypass and not a narrower guard. Measured against the same
  # scratch sshd as the table above, and every one of these suppressed the
  # client's command while returning 0:
  #
  #   COMMAND="/usr/bin/true" <key>      ssh rc=0   nothing ran
  #   CoMmAnD="/usr/bin/true" <key>      ssh rc=0   nothing ran
  #   no-pty,COMMAND="/usr/bin/true"     ssh rc=0   nothing ran
  fcguard "COMMAND=\"/usr/bin/true\" $FC_KEY"
  chk "an uppercase option name is the same option"    1 "$fc_rc"
  fcguard "CoMmAnD=\"/usr/bin/true\" $FC_KEY"
  chk "and a mixed-case one"                           1 "$fc_rc"
  fcguard "no-pty,COMMAND=\"/usr/bin/true\" $FC_KEY"
  chk "and an uppercase one behind another option"     1 "$fc_rc"
  # The options field has to be found from authorized_keys quoting, not from
  # base64-looking text. `AAAA` is valid inside an option value, and ssh-keygen
  # accepts this exact line; cutting at that value used to hide the forced
  # command that follows it.
  FC_COLLISION="from=\"203.0.113.4,AAAA\",command=\"/usr/bin/true\" $FC_KEY"
  printf '%s\n' "$FC_COLLISION" > "$fcd/collision.pub"
  chk "the delimiter-collision fixture is a real key line" 0 \
    "$(ssh-keygen -l -f "$fcd/collision.pub" >/dev/null 2>&1; echo $?)"
  fcguard "$FC_COLLISION"
  chk "AAAA in an option cannot hide a later command"  1 "$fc_rc"

  # `command=` in a quoted value is data, not an option name. sshd only
  # replaces the client command when the comma-separated option itself is
  # named command.
  FC_VALUE_COLLISION="environment=\"NOTE=command=value\" $FC_KEY"
  printf '%s\n' "$FC_VALUE_COLLISION" > "$fcd/value-collision.pub"
  chk "the option-value fixture is a real key line"    0 \
    "$(ssh-keygen -l -f "$fcd/value-collision.pub" >/dev/null 2>&1; echo $?)"
  fcguard "$FC_VALUE_COLLISION"
  chk "command= inside an option value is accepted"    0 "$fc_rc"
  fcguard "environment=\"NOTE=command=value\",command=\"/usr/bin/true\" $FC_KEY"
  chk "but a later command option is still refused"    1 "$fc_rc"

  fcguard "$FC_KEY"
  chk "a plain key still goes through"                 0 "$fc_rc"
  fcguard "from=\"127.0.0.1\" $FC_KEY"
  chk "and one behind a from= restriction"             0 "$fc_rc"
  fcguard "from=\"AAAA.example\" $FC_KEY"
  chk "and AAAA in a benign option is not itself refused" 0 "$fc_rc"
  fcguard "restrict $FC_KEY"
  chk "and one behind restrict, which runs the command" 0 "$fc_rc"
  # The control that keeps the fold on the *question* rather than on the guard:
  # `RESTRICT` is accepted by sshd and runs the client's command, so an
  # uppercase option is not on its own a reason to refuse anything.
  fcguard "RESTRICT $FC_KEY"
  chk "and behind an uppercase restrict, which also runs it" 0 "$fc_rc"
  fcguard ""
  chk "and no key at all"                              0 "$fc_rc"
  # The over-refusal control that decides where the options end. A comment is
  # free text an operator may have anything in, and sshd does not read it as an
  # option — refusing this would refuse a key that works.
  fcguard "$FC_KEY command=in-the-comment"
  chk "a command= in the comment is not an option"     0 "$fc_rc"

  # Source-level, because the behavioural rows above pass on a revision that
  # never calls the guard: it is the call that makes the run stop.
  chk "and the run calls it"                           1 \
    "$(grep -c '^refuse_forced_command_ssh_key$' "$SRC")"
  rm -rf "$fcd"
fi

echo "143. a DB_BIND_ADDRESS or DOCKER_SUBNETS the cluster cannot use is refused"
# Measured on a real cluster with `include_dir = 'conf.d'` and this script's own
# generated file, restarted once per value:
#
#   DB_BIND_ADDRESS       postgres -C   the cluster after the restart
#   172.17.0.1            rc=0          UP, listening on the bridge
#   172.17.0.999          rc=0          UP, WARNING, listening on localhost
#   bogus.invalid         rc=0          UP, WARNING, listening on localhost
#   not a host            rc=0          DOWN, FATAL: invalid list syntax
#
#   DOCKER_SUBNETS        the cluster after the restart
#   172.16.0.0/12         UP, the rule matches
#   not-a-subnet          UP, read as a host name, the rule matches nothing
#   172.16.0.0/99         DOWN, FATAL: invalid CIDR mask in address
#
# Two bands, and the quiet one is the dangerous one: a healthy cluster no
# container can reach. `postgres -C` answers rc=0 on every row including the one
# that will not start, so validating the staged file does not close this — the
# value has to be answered before it is written.
bind_rc=0
bindguard() { ( refuse_unusable_bind_address DB_BIND_ADDRESS "$1" ) >/dev/null 2>&1 && bind_rc=0 || bind_rc=1; }
subguard()  { ( refuse_unusable_subnet DOCKER_SUBNETS "$1" ) >/dev/null 2>&1 && bind_rc=0 || bind_rc=1; }

bindguard 172.17.0.1
chk "the default bridge address goes through"          0 "$bind_rc"
bindguard 10.0.0.5
chk "and any other dotted quad"                        0 "$bind_rc"
bindguard 1.2.3.4
chk "including one this host does not hold"            0 "$bind_rc"
bindguard 172.17.0.999
chk "an octet over 255 is refused"                     1 "$bind_rc"
bindguard bogus.invalid
chk "and a host name, which PostgreSQL only warns on"  1 "$bind_rc"
bindguard "not a host"
chk "and a value with a space, which stops the cluster" 1 "$bind_rc"
bindguard "172.17.0.1'"$'\n'"fsync = off"
chk "and one that closes the quoting of the file"      1 "$bind_rc"
bindguard 172.17.0
chk "and three octets"                                 1 "$bind_rc"
bindguard ""
chk "and nothing at all"                               1 "$bind_rc"

subguard 172.16.0.0/12
chk "the default subnet goes through"                  0 "$bind_rc"
subguard 192.168.0.0/24
chk "and any other network"                            0 "$bind_rc"
subguard 172.16.0.0/32
chk "and a single host as /32"                         0 "$bind_rc"
subguard 172.16.0.0/99
chk "a mask over 32 is refused"                        1 "$bind_rc"
subguard not-a-subnet
chk "and a name, which the rule would never match"     1 "$bind_rc"
subguard "172.16.0.0/12 all trust"
chk "and extra fields, which stop the cluster"         1 "$bind_rc"
subguard 172.16.0.0
chk "and an address with no mask"                      1 "$bind_rc"

chk "and the run asks both before anything is written" 2 \
  "$(grep -c '^refuse_unusable_\(bind_address DB_BIND_ADDRESS\|subnet DOCKER_SUBNETS\)' "$SRC")"
# The liveness half, which no value check can answer: docker0 does not exist
# when the guards above run. Asserted at source level because it needs a
# cluster — measured there as rc=0 bound, rc=2 up-but-not-listening.
chk "and asks the cluster whether it is listening on it" 1 \
  "$(grep -c '^pg_isready -h "\$DB_BIND_ADDRESS"' "$SRC")"

echo "144. an interrupted first append leaves the managed block off the live file"
# The rewrite path was staged and renamed two commits ago; the append that adds
# the block for the first time still wrote into the live file. Measured by
# failing one printf of the three — which is what a disk filling between two
# writes does — and then running the next convergence over what was left:
#
#   fails at  reviewed: live file        next run          fixed: live file
#   BEGIN     unchanged                  adds the block    unchanged
#   the body  BEGIN + END, empty body    rewrites it       BEGIN + END, empty
#   END       BEGIN, no END              REFUSES           unchanged
#   nothing   the whole block            no-op             the whole block
#
# The third row is the finding: the next run stops at the malformed-block check
# and asks for /etc/fstab, /etc/hosts, postgresql.conf or pg_hba.conf to be
# repaired by hand, on a host whose provisioning has just been killed. That
# check is right to refuse — it cannot tell a torn write of this script's from
# an operator's edit — so the fix belongs on the write.
#
# Rows 1, 2 and 4 are unchanged by the fix and are the controls. Row 2 is worth
# keeping visible rather than tidying away: an empty managed block is not a torn
# file, and the next run converges it.
abd=$(mktemp -d)
ab_printf_fail_at=0; ab_printf_n=0
printf() {
  ab_printf_n=$((ab_printf_n + 1))
  [ "$ab_printf_n" != "$ab_printf_fail_at" ] || return 1
  builtin printf "$@"
}
ab_run() { # <fail at nth printf>  -> "<BEGIN count> <END count> <untouched line> <strays>"
  rm -rf "$abd/f"; builtin printf 'UUID=abc / ext4 defaults 0 1\n' > "$abd/f"
  ab_printf_fail_at="$1"; ab_printf_n=0
  ( ensure_block "$abd/f" swap "/swapfile none swap sw 0 0" ) >/dev/null 2>&1
  ab_printf_fail_at=0
  echo "$(grep -c 'BEGIN collavre:swap' "$abd/f") $(grep -c 'END collavre:swap' "$abd/f") $(grep -c '^UUID=abc' "$abd/f") $(ls -A "$abd" | grep -c collavre)"
}
chk "a failed BEGIN leaves the file as it was"          "0 0 1 0" "$(ab_run 1)"
chk "a failed END leaves no half-written block behind"  "0 0 1 0" "$(ab_run 3)"
chk "and no staging file beside it"                     "0 0 1 0" "$(ab_run 3)"
chk "an uninterrupted append still adds the block"      "1 1 1 0" "$(ab_run none)"
# The control that says the next run is not left asking for an editor. Against
# the reviewed revision this is the refusal.
rm -rf "$abd/f"; builtin printf 'UUID=abc / ext4 defaults 0 1\n' > "$abd/f"
ab_printf_fail_at=3; ab_printf_n=0
( ensure_block "$abd/f" swap "/swapfile none swap sw 0 0" ) >/dev/null 2>&1
ab_printf_fail_at=0
ab_next="$( ( ensure_block "$abd/f" swap "/swapfile none swap sw 0 0" ) 2>&1 >/dev/null | grep -c "with no '# END" )"
chk "so the next run converges instead of refusing"     0 "$ab_next"
chk "and the block is there afterwards"                 1 "$(grep -c 'END collavre:swap' "$abd/f")"
unset -f printf
rm -rf "$abd"

echo "146. the SSH hardening drop-in is installed where it can win, and read back"
# sshd_config(5): "for each keyword, the first obtained value will be used", and
# the Include glob is expanded in lexical order. So a "99-" drop-in loses every
# keyword an earlier file has already set — which reads backwards, because a
# high number means "last, therefore final" almost everywhere else.
#
# Ubuntu's cloud images ship 50-cloud-init.conf, and on an existing instance it
# commonly carries `PasswordAuthentication yes`. Measured with `sshd -T` rather
# than read off the manual page, on OpenSSH 9.x/Linux and 10.2/macOS alike:
#
#   drop-ins present                        passwordauth  permitrootlogin
#   50-cloud-init.conf + 99-collavre.conf   yes           yes
#   50-cloud-init.conf + 01-collavre.conf   no            no
#   01-collavre.conf alone (fresh host)     no            no
#
# `kbdinteractiveauthentication no` in all three rows is the control that says
# what went wrong: the 99- file was read the whole time. It lost exactly the
# keywords something else had already set, and gained the one nothing else
# mentions — so nothing about the run looked wrong, and step 3 reported "SSH
# hardening" over a host still taking passwords and root logins.
#
# The rename is necessary and not sufficient, which is why the read-back is the
# other half. A drop-in an operator prefixed 00-, or a directive above the
# Include in sshd_config itself, still wins, and no file name can answer that.
LOGGED=""
log() { LOGGED="$LOGGED $*"; }

vshd="$(mktemp -d)"
mkdir -p "$vshd/sshd_config.d" "$vshd/bin"
printf 'PasswordAuthentication yes\n' > "$vshd/sshd_config.d/00-operator.conf"
printf 'PasswordAuthentication no\nPermitRootLogin no\nKbdInteractiveAuthentication no\n' \
  > "$vshd/sshd_config.d/01-collavre.conf"
printf 'Include %s/sshd_config.d/*.conf\n' "$vshd" > "$vshd/sshd_config"

# <what sshd -T reports> -> 0 when the run continues, 1 when it stops
vh() {
  printf '%s\n' "$1" > "$vshd/eff"
  ( verify_ssh_hardening "$vshd/eff" "$vshd" ) >/dev/null 2>&1 && echo 0 || echo 1
}
vh_eff() { printf 'passwordauthentication %s\npermitrootlogin %s\nkbdinteractiveauthentication %s' "$1" "$2" "$3"; }

chk "an effective config that matches the drop-in passes" 0 "$(vh "$(vh_eff no no no)")"
chk "password authentication still on stops the run"      1 "$(vh "$(vh_eff yes no no)")"
# `prohibit-password` is the Ubuntu default and still admits root by key, so it
# is not the 'no' this script writes.
chk "and root login still on, however narrowly"           1 "$(vh "$(vh_eff no prohibit-password no)")"
chk "and keyboard-interactive still on"                   1 "$(vh "$(vh_eff no no yes)")"

printf '%s\n' "$(vh_eff yes no no)" > "$vshd/eff"
vh_msg="$( ( verify_ssh_hardening "$vshd/eff" "$vshd" ) 2>&1 )"
chk "and the refusal names the file that won"             1 \
  "$(printf '%s' "$vh_msg" | grep -c '00-operator\.conf')"

# Unknown is not wrong. A host where `sshd -T` will not run has answered
# nothing, and stopping over a question that could not be asked would refuse
# hosts that are fine — so that branch warns and the run goes on.
printf '#!/bin/sh\nexit 1\n' > "$vshd/bin/sshd"
chmod +x "$vshd/bin/sshd"
vh_unread="$( ( PATH="$vshd/bin:$PATH"
                log() { printf 'LOG %s\n' "$*"; }
                verify_ssh_hardening "" "$vshd" ) 2>&1; printf 'rc=%s\n' "$?" )"
chk "an sshd -T that will not run warns instead of stopping" 1 \
  "$(printf '%s' "$vh_unread" | grep -c '^rc=0$')"
chk "and says the hardening is unverified"                1 \
  "$(printf '%s' "$vh_unread" | grep -c 'unverified')"
vh_inactive_unread="$( ( PATH="$vshd/bin:$PATH"
  verify_ssh_hardening "" "$vshd" 2 ) 2>&1
  printf 'rc=%s\n' "$?" )"
chk "but an inactive daemon with no valid disk config stops" 1 \
  "$(printf '%s' "$vh_inactive_unread" | grep -c '^rc=1$')"
chk "and names the socket activation risk"                  1 \
  "$(printf '%s' "$vh_inactive_unread" | grep -c 'socket-activated connection')"

# Source level, because every row above passes on a revision that writes the
# drop-in under the losing name and never reads anything back.
chk "the drop-in is written where it sorts first"         1 \
  "$(grep -c "^install_managed_config 'the SSH hardening drop-in' \\\\\$" "$SRC")"
chk "and at the 01- path"                                 1 \
  "$(grep -c '^  /etc/ssh/sshd_config\.d/01-collavre\.conf \\$' "$SRC")"
# And that nothing on this path went back to a truncating write. Both drop-ins
# this script owns are named, because the sysctl one carries
# net.ipv4.ip_nonlocal_bind and loses it the same way.
chk "and neither drop-in is written in place"             0 \
  "$(grep -c '^cat > /etc/\(ssh/sshd_config\.d\|sysctl\.d\)/' "$SRC")"
chk "the sysctl drop-in is staged too"                    1 \
  "$(grep -c "^install_managed_config 'the sysctl drop-in' /etc/sysctl\.d/" "$SRC")"
chk "and the inert 99- file it replaces is removed"       1 \
  "$(grep -c '^rm -f /etc/ssh/sshd_config\.d/99-collavre\.conf$' "$SRC")"
chk "and the run reads back what sshd resolved"           1 \
  "$(grep -cF 'verify_ssh_hardening "" /etc/ssh "$SSH_RELOAD_STATE"' "$SRC")"

# The claim is about what sshd does with two files, so sshd is asked. The name
# and the body both come from the script: a harness that wrote its own 01- file
# would keep passing after the script went back to 99-.
vh_sshd=""
for vh_c in sshd /usr/sbin/sshd; do
  command -v "$vh_c" >/dev/null 2>&1 && { vh_sshd="$vh_c"; break; }
done
vh_effective() { # <config dir> -> "<passwordauthentication> <permitrootlogin>"
  "$vh_sshd" -T -f "$1/sshd_config" 2>/dev/null |
    awk 'tolower($1)=="passwordauthentication"{p=$2}
         tolower($1)=="permitrootlogin"{r=$2}
         END{print p, r}'
}
if [ -z "$vh_sshd" ] || ! command -v ssh-keygen >/dev/null 2>&1; then
  echo "  SKIP no sshd here — the ordering claim is sshd's own and nothing else answers it"
else
  vhr="$(mktemp -d)"
  mkdir -p "$vhr/sshd_config.d"
  ssh-keygen -q -t ed25519 -N '' -f "$vhr/hk" >/dev/null 2>&1
  printf 'Include %s/sshd_config.d/*.conf\nHostKey %s/hk\n' "$vhr" "$vhr" > "$vhr/sshd_config"
  # The shipped write, run rather than replayed: the whole install_managed_config
  # call is lifted out of the script with only its directory redirected, so the
  # file name, the body and the staging all come from the script. A harness that
  # wrote its own 01- file would keep passing after the script went back to 99-.
  vh_call="$(awk "/^install_managed_config 'the SSH hardening drop-in'/ { f = 1 }
                  f { print }
                  f && \$0 !~ /\\\\\$/ { exit }" "$SRC")"
  eval "$(printf '%s\n' "$vh_call" |
            sed "s#/etc/ssh/sshd_config\.d/#$vhr/sshd_config.d/#")"
  vh_name="$(printf '%s\n' "$vh_call" |
               awk '/\/etc\/ssh\/sshd_config\.d\// {
                      sub(/.*sshd_config\.d\//, ""); sub(/[ \\].*/, ""); print; exit }')"
  if [ "$(vh_effective "$vhr")" != "no no" ]; then
    echo "  SKIP sshd -T is not usable here — it could not read even the drop-in alone"
  else
    chk "the drop-in alone hardens a fresh host"          "no no" "$(vh_effective "$vhr")"
    printf 'PasswordAuthentication yes\nPermitRootLogin yes\n' \
      > "$vhr/sshd_config.d/50-cloud-init.conf"
    chk "and still does beside Ubuntu's cloud-init drop-in" "no no" "$(vh_effective "$vhr")"
    # The negative control, and the one that says the assertion above is about
    # the name rather than the content: the same body under the old name.
    mv "$vhr/sshd_config.d/$vh_name" "$vhr/sshd_config.d/99-collavre.conf"
    chk "where a 99- name would have lost both keywords"  "yes yes" "$(vh_effective "$vhr")"
  fi
  rm -rf "$vhr"
fi
rm -rf "$vshd"

echo "147. keys copied from the cloud user are withdrawn by a later rotation"
# The runbook's variable table promises that changing SSH_PUBLIC_KEY on a re-run
# "withdraws the key it replaces". On the empty -> explicit transition it
# withdrew nothing: `record_ssh_key_grant "$SSH_PUBLIC_KEY"` at the call site is
# a no-op when the variable is empty, which is exactly what puts the run on the
# copy-from-the-cloud-user path, so the queue stayed empty and the rotation
# found no predecessor. Measured on the shipped functions:
#
#   run 1  SSH_PUBLIC_KEY=''      authorized: cloud-1 cloud-2      queue: -
#   run 2  SSH_PUBLIC_KEY=<new>   authorized: cloud-1 cloud-2 new  queue: new
#
# on the account that has passwordless sudo and docker.
kd=$(mktemp -d)
K1="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAACLOUDKEYONE cloud-1"
K2="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAACLOUDKEYTWO cloud-2"
KN="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAANEWDEPLOYKEY new"
# No such account on this machine, and the ownership is not what is under test —
# without this the install refuses and every row below reads "withdrawn" off an
# empty file, which is how this fixture first passed while measuring nothing.
# shellcheck disable=SC2329  # called by install_staged_authorized_keys
chown() { :; }
key_rotation() {   # <deploy account> -> "<authorized names>|<queue names>"
  # One name per statement: bash expands every word of a `local` before it
  # performs any of the assignments, so `local a="$1" b="$a"` leaves b empty —
  # and under this suite's `set -u` it aborts the case instead, which is how
  # this was caught rather than silently measuring the wrong directory.
  local acct="$1"
  local h="$kd/$acct" sd="$kd/state.$acct"
  local ak out=''
  rm -rf "$h" "$sd"; mkdir -p "$sd" "$h/ubuntu/.ssh" "$h/$acct/.ssh"
  printf '%s\n%s\n' "$K1" "$K2" > "$h/ubuntu/.ssh/authorized_keys"
  ak="$h/$acct/.ssh/authorized_keys"
  [ "$acct" = ubuntu ] || : > "$ak"
  local k
  for k in '' "$KN"; do
    STATE_DIR="$sd" APP_SSH_USER="$acct" SSH_PUBLIC_KEY="$k"
    record_ssh_key_grant "$SSH_PUBLIC_KEY" >/dev/null 2>&1
    install_authorized_keys "$ak" "$h" >/dev/null 2>&1
    revoke_prior_ssh_key "$ak" >/dev/null 2>&1
  done
  while read -r l; do [ -n "$l" ] && out="$out${l##* } "; done < "$ak"
  out="${out}|"
  [ -s "$sd/ssh_public_keys.$acct" ] &&
    while read -r l; do [ -n "$l" ] && out="$out ${l##* }"; done < "$sd/ssh_public_keys.$acct"
  printf '%s' "$out"
}
chk "a copied cloud key is withdrawn when SSH_PUBLIC_KEY is set" \
  "new | new" "$(key_rotation collavre)"
# The control that decides where the recording may go, and it is the one that
# would be a lockout if it moved: when APP_SSH_USER *is* the cloud user, the
# file is that account's own and this script never wrote it. Queueing it would
# have a later rotation strip the operator's Lightsail key from the account they
# log in as. Copied keys are this script's to withdraw; a cloud account's own
# are not.
chk "but the cloud user's own keys are left alone" \
  "cloud-1 cloud-2 new | new" "$(key_rotation ubuntu)"
# A failed record must stop the run *before* the keys are authorized, which is
# the ordering and not just the recording. Reached through record_ssh_key_grant's
# own failure path, which on a real host is a state directory that cannot be
# written — an ENOSPC on a 512MB instance:
#
#   record        run 1 rc   queued   authorized after the rotation
#   succeeds      0          2        new
#   fails         0          0        cloud-1 cloud-2 new     <- reviewed order
#
# The second row is the defect the fix above was written for, reached through
# its failure path: rc 0, a summary reporting a converged host, and two keys the
# documented rotation will never withdraw — on the account this run is about to
# give docker and passwordless sudo.
#
# The two failures are not symmetric, which is why this order and not the other.
# Recorded-but-not-installed is harmless: revoke_prior_ssh_key skips a queued key
# that is absent from authorized_keys, and append_state_line dedupes, so the
# retry after the disk is freed records nothing twice.
# shellcheck disable=SC2329  # the failure seam, restored below
record_ssh_key_grant() { return 1; }
kf="$kd/failed"; mkdir -p "$kf/ubuntu/.ssh" "$kf/collavre/.ssh" "$kd/state.failed"
printf '%s\n%s\n' "$K1" "$K2" > "$kf/ubuntu/.ssh/authorized_keys"
: > "$kf/collavre/.ssh/authorized_keys"
# shellcheck disable=SC2329  # called by install_staged_authorized_keys
chown() { :; }
STATE_DIR="$kd/state.failed" APP_SSH_USER=collavre SSH_PUBLIC_KEY=''
( install_authorized_keys "$kf/collavre/.ssh/authorized_keys" "$kf" ) >/dev/null 2>&1
chk "a record that fails installs nothing"  "0" \
  "$(grep -c . "$kf/collavre/.ssh/authorized_keys")"
chk "and leaves no staging file behind"     "0" \
  "$(ls -A "$kf/collavre/.ssh" | grep -c collavre)"
STATE_DIR="$kd/state.failed" APP_SSH_USER=collavre SSH_PUBLIC_KEY=''
( install_authorized_keys "$kf/collavre/.ssh/authorized_keys" "$kf" ) >/dev/null 2>&1
chk "and the run is told, rather than reporting a converged host" 1 "$?"
unset -f record_ssh_key_grant chown
eval "$(awk '/^record_ssh_key_grant\(\) \{/ { f = 1 } f { print } f && /^\}/ { f = 0 }' "$SRC")"
rm -rf "$kd"

echo "148. a torn write cannot reach a drop-in this script owns"
# `cat > /etc/ssh/sshd_config.d/01-collavre.conf <<'SSHD'` truncates the live
# file before it writes, so a run killed between the two — an OOM kill or an
# ENOSPC on a 512MB instance — leaves the live drop-in short. Measured against a
# real sshd, with Ubuntu's 50-cloud-init.conf beside it turning both keywords
# back on:
#
#   01-collavre.conf state   bytes   sshd -t   passwordauth  permitrootlogin
#   whole                    77      rc=0      no            no
#   0 bytes (torn at open)    0      rc=0      yes           yes
#   cut after line 1         26      rc=0      no            yes
#   cut mid-directive        36      rc=255    -             -
#
# Two bands, and only the bottom one is loud: it stops sshd from starting, which
# locks the host out at its next boot. The middle two are the quiet ones — sshd
# reads them happily and the hardening is silently reduced or gone, on a host
# whose provisioning was killed rather than one that reported success.
#
# `sshd -t` is what the finding asks for and it cannot close the quiet band: it
# answers rc=0 for the empty file, which is exactly what truncate-at-open leaves.
# So the staged file is asked whether it *says* what it was staged to say.
imcd=$(mktemp -d)
imc_mode=whole
# Only the multi-line write is intercepted — stage_beside returns its path
# through a one-argument printf, and swallowing that would model a failure that
# is not the one under test.
printf() {
  if [ "$imc_mode" != whole ] && [ "$#" -gt 2 ]; then
    case "$imc_mode" in
      short) builtin printf '%s\n' "$2" ;;   # a short write that reported success
      empty) : ;;                            # opened, then nothing landed
      fail) return 1 ;;
    esac
    return 0
  fi
  builtin printf "$@"
}
imc_run() { # <mode> -> "<live lines> <hardened> <strays> <rc>"
  imc_mode=whole
  builtin printf 'PasswordAuthentication yes\n' > "$imcd/dropin"
  imc_mode="$1"
  ( install_managed_config 'the drop-in' "$imcd/dropin" \
      'PasswordAuthentication no' 'PermitRootLogin no' ) >/dev/null 2>&1
  local rc=$?
  imc_mode=whole
  echo "$(grep -c . "$imcd/dropin") $(grep -c '^PasswordAuthentication no$' "$imcd/dropin") $(ls -A "$imcd" | grep -c collavre) $rc"
}
chk "an uninterrupted write installs the whole drop-in"  "2 1 0 0" "$(imc_run whole)"
# The quiet band. Both of these are files every validator accepts, and both are
# refused here because the question asked is what the file says.
chk "a write cut after the first line installs nothing"  "1 0 0 1" "$(imc_run short)"
chk "and one that landed empty is refused too"           "1 0 0 1" "$(imc_run empty)"
chk "and a write that fails outright"                    "1 0 0 1" "$(imc_run fail)"
# Comment and blank lines are written but not read back — they are not what the
# file is for. The sysctl drop-in carries both, so this is a control on it
# rather than a hypothetical.
imc_mode=whole
: > "$imcd/dropin"
( install_managed_config 'the drop-in' "$imcd/dropin" \
    '# Prefer RAM' '' 'vm.swappiness = 10' ) >/dev/null 2>&1
chk "a comment line is still written"                    1 \
  "$(grep -c '^# Prefer RAM$' "$imcd/dropin")"
chk "and the directive beside it"                        1 \
  "$(grep -c '^vm\.swappiness = 10$' "$imcd/dropin")"
unset -f printf
# The rename has to go to the *resolved* path, the way ensure_block and the
# 10-collavre.conf write both do. stage_beside resolves internally, so renaming
# onto the unresolved argument puts the staging file beside the backing file
# and the finished one beside the link:
#
#   /etc/link.conf -> /real/backing.conf
#     link.conf   becomes a REGULAR FILE holding the new content
#     backing.conf  still holds the old
#
# The operator's symlink is replaced, and — the reason this is in *this* case
# rather than filed as tidiness — the staging file sits on the backing file's
# filesystem, so a link that crosses one turns the `mv` into a copy-then-unlink.
# That is the non-atomic write every assertion above is about, reintroduced on
# exactly the hosts where the staging is doing any work.
mkdir -p "$imcd/backing"
builtin printf 'old\n' > "$imcd/backing/real.conf"
ln -s "$imcd/backing/real.conf" "$imcd/link.conf"
( install_managed_config 'the drop-in' "$imcd/link.conf" 'NEW yes' ) >/dev/null 2>&1
chk "a symlinked target is written through, not replaced" "symlink" \
  "$([ -L "$imcd/link.conf" ] && echo symlink || echo regular-file)"
chk "and the backing file is the one that changed"        1 \
  "$(grep -c '^NEW yes$' "$imcd/backing/real.conf")"
# The control: a plain target is unaffected by the resolution, which is what
# says the fix is the rename path and not a second behaviour.
builtin printf 'old\n' > "$imcd/plain.conf"
( install_managed_config 'the drop-in' "$imcd/plain.conf" 'NEW yes' ) >/dev/null 2>&1
chk "a plain target is still rewritten in place"          "1 0" \
  "$(builtin printf '%s %s' "$(grep -c '^NEW yes$' "$imcd/plain.conf")" \
       "$(ls -A "$imcd" | grep -c collavre)")"
rm -rf "$imcd"

echo "149. a BACKUP_RETENTION_DAYS the nightly find cannot use is refused"
# The value is %q-quoted into the generated backup program and used only there,
# as `find -mtime "+$RETENTION_DAYS"`. `bash -n` on the staged program parses it
# and the timer is enabled, so nothing on the provisioning side says anything:
# the value is first read by GNU find, at 03:00, on a host the summary reported
# as converged. Measured by running the generated program with each value,
# GNU findutils 4.8.0:
#
#   BACKUP_RETENTION_DAYS   rc   dumps left      the unit
#   7                       0    the new dump    green
#   seven                   1    new + the old   RED, invalid argument `+seven'
#   ''                      1    new + the old   RED, invalid argument `+'
#   -1                      0    NONE            green, "backup complete: ()"
#
# Two bands again, and the loud one is not the dangerous one. `seven` fails
# every night with the unit red and dumps accumulating until the disk fills —
# the finding, and at least visible in `systemctl list-units --failed`. `-1` is
# the one worth this guard: find takes `+-1`, deletes every dump *including the
# one just taken*, and the program still exits 0 and reports "backup complete"
# for a file that is no longer there.
# BACKUP_AT, because the refusal names the hour the value would otherwise first
# be read at. Without it every "refused" row below is a `set -u` abort on an
# unbound variable rather than the guard answering — the rows go green and
# measure nothing. The message assertion at the bottom is what caught that, and
# is why it is here rather than only the return codes.
ret_rc() {
  ( BACKUP_AT=03:30; refuse_unusable_retention BACKUP_RETENTION_DAYS "$1" ) >/dev/null 2>&1
  echo $?
}
chk "the default is accepted"                            0 "$(ret_rc 7)"
chk "and any other whole number of days"                 0 "$(ret_rc 30)"
# The control that keeps this a check on the spelling rather than on a range:
# `-mtime +0` keeps the dump just taken and drops yesterday's, which is a
# retention an operator may well have chosen.
chk "and zero, which keeps one day"                      0 "$(ret_rc 0)"
chk "a word find rejects is refused"                     1 "$(ret_rc seven)"
chk "and an empty value, which find reads as '+'"        1 "$(ret_rc '')"
chk "and a negative one, which takes the new dump with it" 1 "$(ret_rc -1)"
chk "and a fraction, which has one spelling here"        1 "$(ret_rc 7.5)"
chk "and trailing whitespace"                            1 "$(ret_rc '7 ')"
# The message has to say the host is unchanged, because this refusal is the
# operator's only signal — every other reading of the value happens at 03:00.
ret_msg="$( ( BACKUP_AT=03:30; refuse_unusable_retention BACKUP_RETENTION_DAYS seven ) 2>&1 )"
chk "and the refusal says nothing has been changed"      1 \
  "$(printf '%s' "$ret_msg" | grep -c 'Nothing has been changed')"
# Source level, because every row above passes on a revision that defines the
# guard and never calls it — which is where the run has to refuse, before the
# unit is installed and enabled.
chk "and the run asks before installing the timer"       1 \
  "$(grep -c '^refuse_unusable_retention BACKUP_RETENTION_DAYS "\$BACKUP_RETENTION_DAYS"$' "$SRC")"

echo "150. a running sshd that refused the hardening stops the run"
# `systemctl reload ssh || systemctl reload sshd || true` swallowed a status
# that means two different things. Measured under systemd 252, one unit state
# per row, with ExecReload standing in for sshd's own accept-or-refuse:
#
#   unit state              reload rc   is-active   what it means
#   inactive                1           inactive    nothing to reload
#   not found at all        5           inactive    nothing to reload
#   active, reload ok       0           active      adopted
#   active, reload refused  1           active      still on the OLD config
#
# Rows 1 and 4 share rc=1, so the rc cannot separate them — and row 1 is the
# stock Ubuntu 24.04 state (ssh.socket enabled, ssh.service disabled until
# something connects), not an edge case. A guard on the rc alone would refuse
# every correctly-provisioned host. is-active is the discriminator, and it is
# read from systemctl rather than from the message, which is localised.
systemctl() { # <verb> <unit>
  case "$1 $2" in
    "reload $RELOAD_OK")  return 0 ;;
    "reload $RELOAD_BAD") return 1 ;;
    "reload "*)           return 5 ;;   # unit not found
    "is-active $ACTIVE")  echo active; return 0 ;;
    "is-active "*)        echo inactive; return 3 ;;
  esac
  return 1
}
rsd() { # <ok unit> <failing unit> <active unit> -> 0=adopted, 1=refused, 2=inactive
  RELOAD_OK="${1:-@none}" RELOAD_BAD="${2:-@none}" ACTIVE="${3:-@none}"
  reload_ssh_daemon >/dev/null 2>&1; echo $?
}
chk "an ssh.service that adopts it proceeds"          0 "$(rsd ssh '' ssh)"
chk "and an sshd.service that adopts it"              0 "$(rsd sshd '' sshd)"
# The controls, and the reason this is not a binary status. Both are healthy
# hosts on which BOTH reloads fail; status 2 tells the caller it must rely on
# the configuration on disk before allowing socket activation to start sshd.
chk "a socket-activated host with nothing connected"  2 "$(rsd '' ssh '')"
chk "and a host carrying neither unit"                2 "$(rsd '' '' '')"
# The finding. Same rc as the row above it, opposite meaning.
chk "a running daemon that refuses it stops the run"  1 "$(rsd '' ssh ssh)"
# ssh is absent here and sshd is the one running and refusing, so this also
# says the fallback does not read the first unit's absence as an all-clear for
# the second.
chk "and the same under the sshd name"                1 "$(rsd '' sshd sshd)"
# An ssh.service that adopts it while a stale sshd.service sits there refusing:
# the loop must stop at the first unit that took the reload rather than walk on.
chk "a unit that adopted it ends the search"          0 "$(rsd ssh sshd ssh)"
unset -f systemctl
unset RELOAD_OK RELOAD_BAD ACTIVE
# Source level: the behavioural rows above all pass on a revision that defines
# the function and still swallows its status with `|| true`.
chk "and the run preserves the reload state"          1 \
  "$(grep -cF 'reload_ssh_daemon || SSH_RELOAD_STATE=$?' "$SRC")"
chk "and passes it to disk verification"              1 \
  "$(grep -cF 'verify_ssh_hardening "" /etc/ssh "$SSH_RELOAD_STATE"' "$SRC")"
chk "rather than discarding the status"               0 \
  "$(grep -c '^systemctl reload ssh .*|| true$' "$SRC")"

echo "151. the Docker apt source is installed atomically"
docker_source_block="$(
  awk '
    /^if \[ -n "\$DOCKER_WANT" \]; then$/ { f = 1 }
    f { print }
    f && /^fi$/ { exit }
  ' "$SRC"
)"
chk "the live source is written through the staging helper" 1 \
  "$(grep -c "install_managed_config 'the Docker apt source'" <<<"$docker_source_block")"
chk "and never truncated by a heredoc redirection"           0 \
  "$(grep -c 'cat > /etc/apt/sources.list.d/docker.list' <<<"$docker_source_block")"
chk "the staged source is installed before apt reads it"     1 \
  "$(awk '
      /install_managed_config .*Docker apt source/ { installed = NR }
      /apt_get update -y/ { updated = NR }
      END {
	if (installed && updated && installed < updated) print 1
	else print 0
      }
    ' <<<"$docker_source_block")"

echo "152. a missing or incomplete launch record cannot accompany success"
saved_launch_settings="$LAUNCH_SETTINGS"
LAUNCH_SETTINGS='APP_SSH_USER DB_USER BACKUP_S3_URI'
APP_SSH_USER=collavre
DB_USER=collavre_user
BACKUP_S3_URI=s3://collavre-backups/pg
record_dir="$(mktemp -d)"
record_launch_settings "$record_dir" >/dev/null 2>&1
chk "a successful write records every setting"              0 \
  "$(launch_record_is_complete "$record_dir/launch.env"; echo $?)"

saved_write_state_file="$(declare -f write_state_file)"
saved_log="$(declare -f log)"
log() { printf '%s\n' "$*"; }
write_state_file() { return 1; }
record_out="$(record_launch_settings "$record_dir" 2>&1)"
chk "a failed replacement with a complete prior record warns" 0 "$?"
chk "and identifies that record as complete"                  1 \
  "$(grep -c 'complete previous record is intact' <<<"$record_out")"

rm -f "$record_dir/launch.env"
record_status=0
record_out="$(record_launch_settings "$record_dir" 2>&1)" || record_status=$?
chk "a failed first record stops the run"                     1 "$record_status"
chk "and names the missing complete record"                   1 \
  "$(grep -c 'no complete previous record remains' <<<"$record_out")"

printf 'APP_SSH_USER=collavre\nDB_USER=collavre_user\n' > "$record_dir/launch.env"
record_status=0
record_out="$(record_launch_settings "$record_dir" 2>&1)" || record_status=$?
chk "an incomplete prior record also stops the run"           1 "$record_status"

eval "$saved_write_state_file"
rm -f "$record_dir/launch.env"
mkdir "$record_dir/launch.env"
record_status=0
record_out="$(record_launch_settings "$record_dir" 2>&1)" || record_status=$?
chk "a directory at the record path is not mistaken for a write" 1 "$record_status"
chk "and no staging file is moved inside it"                       0 \
  "$(find "$record_dir/launch.env" -mindepth 1 -maxdepth 1 | wc -l | tr -d ' ')"
chk "so the success marker is created only after recording"   1 \
  "$(awk '
      /^record_launch_settings$/ { recorded = NR }
      /^touch "\$MARKER"$/ { marked = NR }
      END {
	if (recorded && marked && recorded < marked) print 1
	else print 0
      }
    ' "$SRC")"
eval "$saved_log"
LAUNCH_SETTINGS="$saved_launch_settings"
rm -rf "$record_dir"

echo "153. the PostgreSQL apt source is installed atomically"
postgres_source_block="$(
  awk '
    /^if ! \[ -d "\/etc\/postgresql\/\$PG_MAJOR\/main" \]; then$/ { f = 1 }
    f { print }
    f && /^fi$/ { exit }
  ' "$SRC"
)"
chk "the live source is written through the staging helper" 1 \
  "$(grep -c "install_managed_config 'the PostgreSQL apt source'" <<<"$postgres_source_block")"
chk "and never truncated by a heredoc redirection"           0 \
  "$(grep -c 'cat > /etc/apt/sources.list.d/pgdg.list' <<<"$postgres_source_block")"
chk "the staged source is installed before apt reads it"     1 \
  "$(awk '
      /install_managed_config .*PostgreSQL apt source/ { installed = NR }
      /apt_get update -y/ { updated = NR }
      END {
	if (installed && updated && installed < updated) print 1
	else print 0
      }
    ' <<<"$postgres_source_block")"

echo "154. the Docker signing key is installed atomically"
download_dir="$(mktemp -d)"
printf 'old-key\n' > "$download_dir/docker.asc"
ln -s "$download_dir/docker.asc" "$download_dir/docker-link.asc"
DOWNLOAD_RESULT=fail
# shellcheck disable=SC2329  # called by extracted install_downloaded_file
curl() {
  local output=''
  while [ "$#" -gt 0 ]; do
    if [ "$1" = -o ]; then
      output="$2"
      shift 2
    else
      shift
    fi
  done
  printf '%s\n' "${DOWNLOAD_RESULT}-key" > "$output"
  [ "$DOWNLOAD_RESULT" = complete ]
}
download_status=0
( install_downloaded_file 'the Docker signing key' \
    https://example.invalid/docker.asc "$download_dir/docker-link.asc" \
  ) >/dev/null 2>&1 || download_status=$?
chk "a failed download leaves the live key intact"           old-key \
  "$(cat "$download_dir/docker.asc")"
chk "and reports failure"                                    1 "$download_status"
chk "and removes its incomplete sibling"                     0 \
  "$(find "$download_dir" -name 'docker.asc.collavre.*' | wc -l | tr -d ' ')"

DOWNLOAD_RESULT=complete
install_downloaded_file 'the Docker signing key' \
  https://example.invalid/docker.asc "$download_dir/docker-link.asc"
chk "a complete download replaces the key"                   complete-key \
  "$(cat "$download_dir/docker.asc")"
chk "and preserves a symlinked target"                        symlink \
  "$([ -L "$download_dir/docker-link.asc" ] && echo symlink || echo regular-file)"
unset -f curl
rm -rf "$download_dir"

chk "the Docker step never downloads into the live key"      0 \
  "$(grep -c -- '-o /etc/apt/keyrings/docker.asc' <<<"$docker_source_block")"
chk "and installs the key before publishing its source"      1 \
  "$(awk '
      /install_downloaded_file .*Docker signing key/ { installed = NR }
      /install_managed_config .*Docker apt source/ { published = NR }
      END {
	if (installed && published && installed < published) print 1
	else print 0
      }
    ' <<<"$docker_source_block")"

echo
if [ "$fail" = 0 ]; then echo "ALL PASS"; else echo "FAILURES"; fi
exit "$fail"
