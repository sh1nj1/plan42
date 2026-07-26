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
  /^(ensure_block|ensure_sudoers|in_group|revoke_prior_deploy_user|ensure_ufw_rule|ssh_already_allowed|ensure_ssh_rule|install_authorized_keys|install_deploy_ssh_dir|reassign_prior_db_role|refuse_superuser_db_rotation|revoke_prior_ssh_key|ensure_cluster_on_default_port|ensure_swapfile|allocate_swapfile|ensure_docker_log_caps|dedupe_authorized_keys|install_staged_authorized_keys)\(\) \{/ { f = 1 }
  f { print }
  f && /^\}/ { f = 0 }
' "$SRC")"

for fn in die ensure_block ensure_sudoers in_group revoke_prior_deploy_user \
          ensure_ufw_rule ssh_already_allowed ensure_ssh_rule \
          install_authorized_keys install_deploy_ssh_dir reassign_prior_db_role \
          refuse_superuser_db_rotation revoke_prior_ssh_key \
          ensure_cluster_on_default_port ensure_swapfile allocate_swapfile \
          ensure_docker_log_caps dedupe_authorized_keys \
          install_staged_authorized_keys; do
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

echo "18. and the marker is not advanced, so the next run retries"
# Advancing it here would forget which account still holds root — a permanent
# silent failure rather than one the next FORCE=1 run picks up.
chk "marker still names the unrevoked user" "legacy" "$(cat "$d4/deploy_user")"
usermod() { usermod_host "$@"; }             # the host is healthy again
revoke deploybot "$d4/deploy_user"           # the retry, on a healthy host
chk "the retry revokes it"     0 "$(printf '%s\n' "$GROUPS_OF" | tr ' ' '\n' | grep -cxF docker)"
chk "and then advances" "deploybot" "$(cat "$d4/deploy_user")"

unset -f id gpasswd usermod usermod_host groupadd log revoke supp_holds drop_word

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
  printf '%s' "$recipe" | sed 's/<instance-ip>/203.0.113.10/g' > "$work/recipe.sh"
  mkdir -p "$work/bin"
  cat > "$work/bin/ssh" <<'STUB'
#!/usr/bin/env bash
case "$*" in
  *"ALTER ROLE collavre_user SUPERUSER"*)   echo GRANT  >>"$TRACE" ;;
  *"ALTER ROLE collavre_user NOSUPERUSER"*) echo REVOKE >>"$TRACE"
                                            [ -z "$FAIL_REVOKE" ] || exit 255 ;;
  *"sudo rm"*)                              echo RM_STAGED >>"$TRACE" ;;
  *"sudo install"*)                         echo STAGE     >>"$TRACE"
                                            [ -z "$FAIL_STAGE" ] || exit 1 ;;
  *)                                        echo ssh       >>"$TRACE" ;;
esac
STUB
  printf '#!/usr/bin/env bash\necho scp >>"$TRACE"\n[ -z "$FAIL_SCP" ] || exit 1\n' \
    > "$work/bin/scp"
  cat > "$work/bin/kamal.sh" <<'STUB'
#!/usr/bin/env bash
echo "kamal:$1${2:+ $2}" >>"$TRACE"
[ "${1:-}" != app ] || [ "${2:-}" != stop ] || [ -z "$FAIL_STOP" ] || exit 1
[ "${1:-}" != app ] || [ "${2:-}" != exec ] || [ -z "$FAIL_COPY" ] || exit 1
STUB
  chmod +x "$work/bin"/*
  cp "$work/bin/kamal.sh" "$work/kamal.sh"

  TRACE="$work/trace"; : > "$TRACE"
  export TRACE FAIL_COPY="${FAIL_COPY:-}" FAIL_REVOKE="${FAIL_REVOKE:-}"
  export FAIL_SCP="${FAIL_SCP:-}" FAIL_STAGE="${FAIL_STAGE:-}"
  export FAIL_STOP="${FAIL_STOP:-}"
  RECIPE_OUT="$(cd "$work" && PATH="$work/bin:$PATH" bash ./recipe.sh 2>&1)"
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
# If the marker advanced, no later run would ever retry the withdrawal.
chk "marker still names the old key" "$OLD" "$(cat "$st3/ssh_public_key")"
case "$LOGGED" in
  *WARNING*"still authorized"*) echo "  ok   the failure is reported, not claimed as a success" ;;
  *) echo "  FAIL silent or reported as withdrawn: $LOGGED"; fail=1 ;;
esac

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
chk "marker still names the old key" "$OLD" "$(cat "$st4/ssh_public_key")"
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
chk "staged in the target's own directory" \
  "$(dirname "$AK")" "$(dirname "$(head -1 "$TEMPLATE_LOG")")"
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
# shellcheck disable=SC2034  # read by reassign_prior_db_role, eval'd from the script
DB_NAME=collavre_production
# shellcheck disable=SC2329  # called by reassign_prior_db_role
psql_as_postgres() {
  case "$2" in
    *"count(*)"*) printf '%s\n' "$ROLE_EXISTS"; return 0 ;;
    *rolsuper*)   printf '%s\n' "$ROLE_IS_SUPER"; return 0 ;;
  esac
  SQL="$SQL|$2"
}
# shellcheck disable=SC2329  # called by reassign_prior_db_role
log() { LOGGED="$LOGGED $*"; }
rotate() { SQL=""; LOGGED=""; reassign_prior_db_role "$@"; }

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
rotate collavre_user "$d3/db_user"
chk "no SQL" "" "$SQL$LOGGED"

echo "49. a superuser predecessor stops the run rather than half-rotating it"
# DB_USER=postgres on a first run is legal, and the rotation away from it cannot
# be completed: PostgreSQL refuses to reassign a superuser's objects at all. The
# earlier form warned and returned, by which point the caller's SQL had already
# moved the database — so the new role owned it and could not read one table,
# and the advanced marker meant no later run looked at the old role again.
printf 'postgres\n' > "$d3/db_user"
ROLE_IS_SUPER=t
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
  printf '%s' "$move" | sed 's/<instance-ip>/203.0.113.10/g' > "$work/recipe.sh"

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
# What is asserted here is the part that regresses silently: the limit is put
# back on EVERY path. A database left at 0 refuses the app at boot, and the
# error it gives reads like a connection-pool problem rather than like a step
# this block forgot to undo.

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
  cat > "$work/bin/psql" <<'STUB'
#!/usr/bin/env bash
sql="${*: -1}"
case "$sql" in
  *"CONNECTION LIMIT 0"*)      echo "limit:0"          >>"$TRACE" ;;
  *"CONNECTION LIMIT -1"*)     echo "limit:reopened"   >>"$TRACE" ;;
  *pg_terminate_backend*)      echo "terminate"        >>"$TRACE"; echo "${KILLED:-0}" ;;
  *"count(*)"*)                echo "count"            >>"$TRACE"; printf '%s' "$LIVE" ;;
  *usename*)                   echo "listing"          >>"$TRACE" ;;
esac
STUB
  cat > "$work/bin/pg_restore" <<'STUB'
#!/usr/bin/env bash
echo "PG_RESTORE_RAN" >>"$TRACE"
[ -z "$FAIL_RESTORE" ] || exit 1
STUB
  chmod +x "$work/bin"/*

  TRACE="$work/trace"; : > "$TRACE"
  # ${LIVE-0}, not ${LIVE:-0}: the empty string is a case under test — it is what
  # a failed check returns — and :- would quietly turn it back into "0", making
  # the one assertion about a broken gate pass for the wrong reason.
  export TRACE LIVE="${LIVE-0}" KILLED="${KILLED:-0}" FAIL_RESTORE="${FAIL_RESTORE:-}"
  R_OUT="$(cd "$work" && PATH="$work/bin:$PATH" bash ./recipe.sh 2>&1)"
  R_TRACE="$(paste -sd'|' "$TRACE")"
  rm -rf "$work"
}

echo "83. the restore shuts the database before it looks, and re-opens after"
LIVE=0 KILLED=2 FAIL_RESTORE='' run_restore
chk "door shut first"        "limit:0" "$(cut -d'|' -f1 <<<"$R_TRACE")"
chk "survivors terminated"   1 "$(grep -c '^terminate$' <<<"${R_TRACE//|/$'\n'}")"
# The order is the whole point: counting before the limit is applied only says
# the app happened to be between connections at that instant.
chk "counted only after the door was shut" 1 \
  "$(grep -q 'limit:0|terminate|count' <<<"$R_TRACE" && echo 1 || echo 0)"
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

echo "86. a FAILED restore still re-opens, or the app cannot boot to be fixed"
LIVE=0 KILLED=0 FAIL_RESTORE=1 run_restore
chk "restore attempted"  1 "$(grep -c '^PG_RESTORE_RAN$' <<<"${R_TRACE//|/$'\n'}")"
chk "re-opened"          1 "$(grep -c '^limit:reopened$' <<<"${R_TRACE//|/$'\n'}")"
chk "told it may be half-done" 1 "$(grep -c 'RESTORE FAILED' <<<"$R_OUT")"
chk "not told to boot"   0 "$(grep -c 'app boot' <<<"$R_OUT")"

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
unset -f chown chmod mv
chk "chown ran on the staging file" 1 "$(grep -c "^chown collavre:collavre $KEYS\.sort\." "$order")"
chk "chmod ran on the staging file" 1 "$(grep -c "^chmod 0600 $KEYS\.sort\." "$order")"
mv_at=$(grep -n '^mv ' "$order" | cut -d: -f1); chmod_at=$(grep -n '^chmod ' "$order" | cut -d: -f1)
chk "both before the rename"        1 \
  "$([ -n "$mv_at" ] && [ -n "$chmod_at" ] && [ "$mv_at" -gt "$chmod_at" ] && echo 1 || echo 0)"
chk "the live file ends 0600"       600 "$(stat -c %a "$KEYS" 2>/dev/null || stat -f %Lp "$KEYS")"

echo
if [ "$fail" = 0 ]; then echo "ALL PASS"; else echo "FAILURES"; fi
exit "$fail"
