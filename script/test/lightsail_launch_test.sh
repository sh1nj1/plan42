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
  /^(ensure_block|ensure_sudoers|revoke_prior_deploy_user|ensure_ufw_rule|ssh_already_allowed|ensure_ssh_rule)\(\) \{/ { f = 1 }
  f { print }
  f && /^\}/ { f = 0 }
' "$SRC")"

for fn in die ensure_block ensure_sudoers revoke_prior_deploy_user \
          ensure_ufw_rule ssh_already_allowed ensure_ssh_rule; do
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

echo "15. the postgres rule is added once and recorded"
d=$(mktemp -d)
UFW_CALLS=""
ensure_ufw_rule postgres "allow from 172.17.0.0/16 to 172.17.0.1 port 5432 proto tcp" \
  "$d/ufw_postgres"
chk "rule added" "|allow from 172.17.0.0/16 to 172.17.0.1 port 5432 proto tcp" "$UFW_CALLS"
chk "recorded"   "allow from 172.17.0.0/16 to 172.17.0.1 port 5432 proto tcp" \
  "$(cat "$d/ufw_postgres")"

echo "16. an unchanged rule deletes nothing"
# The common re-run. ufw skips re-adding an identical rule itself, so the only
# thing that must not happen here is a delete.
UFW_CALLS=""; LOGGED=""
ensure_ufw_rule postgres "allow from 172.17.0.0/16 to 172.17.0.1 port 5432 proto tcp" \
  "$d/ufw_postgres"
chk "no delete" 0 "$(printf '%s' "$UFW_CALLS" | grep -c delete)"

echo "17. a changed rule withdraws the old one instead of accumulating"
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

echo "18. unrelated operator rules are never touched"
# The whole reason `ufw reset` is gone: a re-run must not disturb a VPN,
# monitoring or allowlist rule this script knows nothing about.
chk "only our own rule deleted" 1 "$(printf '%s' "$UFW_CALLS" | grep -c delete)"
chk "no reset"                  0 "$(printf '%s' "$UFW_CALLS" | grep -c reset)"

echo "19. SSH already allowed is detected in every form ufw prints it"
for s in "22/tcp                     ALLOW       Anywhere" \
         "22                         ALLOW IN    Anywhere" \
         "OpenSSH                    ALLOW       Anywhere" \
         "22/tcp (v6)                ALLOW       Anywhere (v6)" \
         "22/tcp                     ALLOW IN    203.0.113.4"; do
  STATUS="$s"
  ssh_already_allowed
  chk "detected: ${s%% *}${s##*ALLOW}" 0 "$?"
done

echo "20. a narrowed SSH rule survives the re-run that finds it"
# The rule an operator most plausibly tightens by hand. Re-adding the blanket
# `allow OpenSSH` on top would reopen 22 to the internet and look like a no-op.
STATUS="22/tcp                     ALLOW IN    203.0.113.4"
UFW_CALLS=""
ensure_ssh_rule
chk "blanket rule not added" "" "$UFW_CALLS"

echo "21. no SSH rule at all means one is added, never assumed"
# Failing the other way enables a deny-by-default firewall on a host with no
# way back in, so every uncertain status must land here.
for s in "Status: inactive" \
         "80/tcp                     ALLOW       Anywhere" \
         "2222/tcp                   ALLOW       Anywhere" \
         "22/tcp                     DENY        Anywhere" \
         ""; do
  STATUS="$s"
  UFW_CALLS=""
  ensure_ssh_rule
  chk "rule added for [${s:-empty status}]" "|allow OpenSSH" "$UFW_CALLS"
done

echo "22. a missing OpenSSH profile falls back to the port, it does not give up"
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

# The fenced bash block containing copy_status= — located by content, so the
# test follows the recipe if it moves within the page.
recipe="$(awk '
  /^  ```bash$/ { inb = 1; buf = ""; next }
  /^  ```$/     { if (inb && buf ~ /copy_status=/) { printf "%s", buf; exit } inb = 0; next }
  inb           { line = $0; sub(/^  /, "", line); buf = buf line "\n" }
' "$DOC")"
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
  *"sudo install"*)                         echo STAGE     >>"$TRACE" ;;
  *)                                        echo ssh       >>"$TRACE" ;;
esac
STUB
  printf '#!/usr/bin/env bash\necho scp >>"$TRACE"\n' > "$work/bin/scp"
  cat > "$work/bin/kamal.sh" <<'STUB'
#!/usr/bin/env bash
echo "kamal:$1${2:+ $2}" >>"$TRACE"
[ "${1:-}" != app ] || [ "${2:-}" != exec ] || [ -z "$FAIL_COPY" ] || exit 1
STUB
  chmod +x "$work/bin"/*
  cp "$work/bin/kamal.sh" "$work/kamal.sh"

  TRACE="$work/trace"; : > "$TRACE"
  export TRACE FAIL_COPY="${FAIL_COPY:-}" FAIL_REVOKE="${FAIL_REVOKE:-}"
  RECIPE_OUT="$(cd "$work" && PATH="$work/bin:$PATH" bash ./recipe.sh 2>&1)"
  RECIPE_TRACE="$(paste -sd'|' "$TRACE")"
  rm -rf "$work"
}

echo "23. a clean cutover cleans up and boots"
FAIL_COPY='' FAIL_REVOKE='' run_cutover
chk "staged file removed" 1 "$(grep -c RM_STAGED <<<"${RECIPE_TRACE//|/$'\n'}")"
chk "app booted"          1 "$(grep -cx 'kamal:app boot' <<<"${RECIPE_TRACE//|/$'\n'}")"

echo "24. a failed copy does not boot, and keeps the file the retry needs"
# MIGRATION_RUN_RESET drops the schema before loading, so a copy that dies
# partway leaves the database empty or half-populated. Booting serves that.
# The `sudo rm` is the other half: it destroys the staged SQLite file, so a
# retry would need another full scp of production rather than a re-run.
FAIL_COPY=1 FAIL_REVOKE='' run_cutover
chk "app NOT booted"          0 "$(grep -cx 'kamal:app boot' <<<"${RECIPE_TRACE//|/$'\n'}")"
chk "staged file kept"        0 "$(grep -c RM_STAGED <<<"${RECIPE_TRACE//|/$'\n'}")"
chk "grant still taken back"  1 "$(grep -cx REVOKE <<<"${RECIPE_TRACE//|/$'\n'}")"
case "$RECIPE_OUT" in
  *"COPY FAILED"*"left stopped"*) echo "  ok   operator told what state it is in" ;;
  *) echo "  FAIL silent or partial: $RECIPE_OUT"; fail=1 ;;
esac

echo "25. a failed revoke does not boot the credential-bearing container"
# collavre_user is the role in DATABASE_URL. Booting while it is still a
# superuser hands every app container that privilege.
FAIL_COPY='' FAIL_REVOKE=1 run_cutover
chk "app NOT booted" 0 "$(grep -cx 'kamal:app boot' <<<"${RECIPE_TRACE//|/$'\n'}")"
case "$RECIPE_OUT" in
  *"REVOKE FAILED"*"left stopped"*) echo "  ok   the still-superuser role is reported" ;;
  *) echo "  FAIL silent: $RECIPE_OUT"; fail=1 ;;
esac

echo "26. both failing reports both, not just the first"
FAIL_COPY=1 FAIL_REVOKE=1 run_cutover
chk "app NOT booted" 0 "$(grep -cx 'kamal:app boot' <<<"${RECIPE_TRACE//|/$'\n'}")"
case "$RECIPE_OUT" in
  *"REVOKE FAILED"*"COPY FAILED"*) echo "  ok   both reported" ;;
  *) echo "  FAIL one masked the other: $RECIPE_OUT"; fail=1 ;;
esac

echo
if [ "$fail" = 0 ]; then echo "ALL PASS"; else echo "FAILURES"; fi
exit "$fail"
