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
  /^(ensure_block|ensure_sudoers|revoke_prior_deploy_user|ensure_ufw_rule|ssh_already_allowed|ensure_ssh_rule|install_authorized_keys|reassign_prior_db_role|revoke_prior_ssh_key)\(\) \{/ { f = 1 }
  f { print }
  f && /^\}/ { f = 0 }
' "$SRC")"

for fn in die ensure_block ensure_sudoers revoke_prior_deploy_user \
          ensure_ufw_rule ssh_already_allowed ensure_ssh_rule \
          install_authorized_keys reassign_prior_db_role revoke_prior_ssh_key; do
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

# extract_recipe <marker> — the fenced bash block containing <marker>, located
# by content, so a test follows its recipe if it moves within the page.
extract_recipe() {
  awk -v want="$1" '
    /^  ```bash$/ { inb = 1; buf = ""; next }
    /^  ```$/     { if (inb && buf ~ want) { printf "%s", buf; exit } inb = 0; next }
    inb           { line = $0; sub(/^  /, "", line); buf = buf line "\n" }
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
[ "${1:-}" != app ] || [ "${2:-}" != exec ] || [ -z "$FAIL_COPY" ] || exit 1
STUB
  chmod +x "$work/bin"/*
  cp "$work/bin/kamal.sh" "$work/kamal.sh"

  TRACE="$work/trace"; : > "$TRACE"
  export TRACE FAIL_COPY="${FAIL_COPY:-}" FAIL_REVOKE="${FAIL_REVOKE:-}"
  export FAIL_SCP="${FAIL_SCP:-}" FAIL_STAGE="${FAIL_STAGE:-}"
  RECIPE_OUT="$(cd "$work" && PATH="$work/bin:$PATH" bash ./recipe.sh 2>&1)"
  RECIPE_TRACE="$(paste -sd'|' "$TRACE")"
  rm -rf "$work"
}

echo "23. a clean cutover cleans up and boots"
FAIL_COPY='' FAIL_REVOKE='' FAIL_SCP='' FAIL_STAGE='' run_cutover
chk "staged file removed" 1 "$(grep -c RM_STAGED <<<"${RECIPE_TRACE//|/$'\n'}")"
chk "app booted"          1 "$(grep -cx 'kamal:app boot' <<<"${RECIPE_TRACE//|/$'\n'}")"

echo "24. a failed copy does not boot, and keeps the file the retry needs"
# MIGRATION_RUN_RESET drops the schema before loading, so a copy that dies
# partway leaves the database empty or half-populated. Booting serves that.
# The `sudo rm` is the other half: it destroys the staged SQLite file, so a
# retry would need another full scp of production rather than a re-run.
FAIL_COPY=1 FAIL_REVOKE='' FAIL_SCP='' FAIL_STAGE='' run_cutover
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
FAIL_COPY='' FAIL_REVOKE=1 FAIL_SCP='' FAIL_STAGE='' run_cutover
chk "app NOT booted" 0 "$(grep -cx 'kamal:app boot' <<<"${RECIPE_TRACE//|/$'\n'}")"
case "$RECIPE_OUT" in
  *"REVOKE FAILED"*"left stopped"*) echo "  ok   the still-superuser role is reported" ;;
  *) echo "  FAIL silent: $RECIPE_OUT"; fail=1 ;;
esac

echo "26. both failing reports both, not just the first"
FAIL_COPY=1 FAIL_REVOKE=1 FAIL_SCP='' FAIL_STAGE='' run_cutover
chk "app NOT booted" 0 "$(grep -cx 'kamal:app boot' <<<"${RECIPE_TRACE//|/$'\n'}")"
case "$RECIPE_OUT" in
  *"REVOKE FAILED"*"COPY FAILED"*) echo "  ok   both reported" ;;
  *) echo "  FAIL one masked the other: $RECIPE_OUT"; fail=1 ;;
esac

echo "27. a failed scp never converts, so a stale snapshot cannot be restored"
# The task loads from the file in the VOLUME, not from the one scp just sent.
# Case 24 deliberately keeps the staged file so a retry need not re-copy — so
# on a retry the volume holds the previous attempt's snapshot. Ungated, a
# failed scp converts from THAT: production silently rolled back to older data,
# reported as success, and the evidence deleted afterwards.
FAIL_COPY='' FAIL_REVOKE='' FAIL_SCP=1 FAIL_STAGE='' run_cutover
chk "no conversion ran"   0 "$(grep -cx 'kamal:app exec' <<<"${RECIPE_TRACE//|/$'\n'}")"
chk "no superuser granted" 0 "$(grep -cx GRANT <<<"${RECIPE_TRACE//|/$'\n'}")"
chk "app NOT booted"      0 "$(grep -cx 'kamal:app boot' <<<"${RECIPE_TRACE//|/$'\n'}")"
chk "stale file NOT deleted" 0 "$(grep -c RM_STAGED <<<"${RECIPE_TRACE//|/$'\n'}")"
case "$RECIPE_OUT" in
  *"STAGING FAILED"*"stale"*) echo "  ok   the retry hazard is named, not just the failure" ;;
  *) echo "  FAIL silent or vague: $RECIPE_OUT"; fail=1 ;;
esac

echo "28. a failed install into the volume is caught too, not just the scp"
# scp can succeed to /tmp and the privileged install still fail — no space,
# no docker group, volume gone.
FAIL_COPY='' FAIL_REVOKE='' FAIL_SCP='' FAIL_STAGE=1 run_cutover
chk "no conversion ran"    0 "$(grep -cx 'kamal:app exec' <<<"${RECIPE_TRACE//|/$'\n'}")"
chk "no superuser granted" 0 "$(grep -cx GRANT <<<"${RECIPE_TRACE//|/$'\n'}")"
chk "app NOT booted"       0 "$(grep -cx 'kamal:app boot' <<<"${RECIPE_TRACE//|/$'\n'}")"

echo "29. staging renames into place rather than writing the live path directly"
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
[ "${1:-}" != app ] || [ "${2:-}" != exec ] || [ -z "$FAIL_LOAD" ] || exit 1
STUB
  chmod +x "$work/bin"/*
  cp "$work/bin/kamal.sh" "$work/kamal.sh"
  TRACE="$work/trace"; : > "$TRACE"
  export TRACE FAIL_LOAD="${FAIL_LOAD:-}"
  FRESH_OUT="$(cd "$work" && PATH="$work/bin:$PATH" bash ./recipe.sh 2>&1)"
  FRESH_TRACE="$(paste -sd'|' "$TRACE")"
  rm -rf "$work"
}

echo "30. a clean fresh install prints the admin password and boots"
FAIL_LOAD='' run_fresh
chk "app stopped first" 1 "$(grep -cx 'kamal:app stop' <<<"${FRESH_TRACE//|/$'\n'}")"
chk "app booted"        1 "$(grep -cx 'kamal:app boot' <<<"${FRESH_TRACE//|/$'\n'}")"

echo "31. a failed schema load does not boot the app onto a partial schema"
# db:schema:load drops and recreates every table, and db:seed is what creates
# the first admin — so a load that resets the database but does not finish
# leaves an app with no way to sign in and no owner on any record.
FAIL_LOAD=1 run_fresh
chk "app NOT booted" 0 "$(grep -cx 'kamal:app boot' <<<"${FRESH_TRACE//|/$'\n'}")"
case "$FRESH_OUT" in
  *"LOAD FAILED"*"left stopped"*) echo "  ok   operator told what state it is in" ;;
  *) echo "  FAIL silent or partial: $FRESH_OUT"; fail=1 ;;
esac

# --- install_authorized_keys ------------------------------------------------
#
# The failure this guards is not a lost key but an aborted run: `cat f >> f` is
# an error under GNU cat, and `set -e` would end provisioning at that line.

LOGGED=""
# shellcheck disable=SC2329  # called by install_authorized_keys, eval'd from the script
log() { LOGGED="$LOGGED $*"; }

echo "32. the deploy user's own keys are not copied onto themselves"
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

echo "33. a separate deploy user still inherits the cloud user's keys"
mkdir -p "$h/collavre/.ssh"; : > "$h/collavre/.ssh/authorized_keys"
SSH_PUBLIC_KEY="" LOGGED=""
install_authorized_keys "$h/collavre/.ssh/authorized_keys" "$h"
chk "cloud key copied" 1 "$(grep -c CLOUDKEY "$h/collavre/.ssh/authorized_keys")"

echo "34. an explicit SSH_PUBLIC_KEY is added once, not once per run"
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

echo "35. rotating SSH_PUBLIC_KEY withdraws the key the last run installed"
printf '%s\n%s\n' "$OLD" "$OPERATOR" > "$AK"
printf '%s\n' "$OLD" > "$st/ssh_public_key"
SSH_PUBLIC_KEY="$NEW" LOGGED=""
install_authorized_keys "$AK" "$h"
revoke_prior_ssh_key "$AK" "$st/ssh_public_key"
chk "the new key is authorized"    1 "$(grep -cxF "$NEW" "$AK")"
chk "the retired key is gone"      0 "$(grep -cxF "$OLD" "$AK")"
chk "an operator's own key stays"  1 "$(grep -cxF "$OPERATOR" "$AK")"
chk "state advanced to the new key" "$NEW" "$(cat "$st/ssh_public_key")"

echo "36. an unchanged SSH_PUBLIC_KEY withdraws nothing"
before="$(cat "$AK")"
revoke_prior_ssh_key "$AK" "$st/ssh_public_key"
chk "authorized_keys untouched" "$before" "$(cat "$AK")"

echo "37. an empty SSH_PUBLIC_KEY means 'keep the cloud keys', not 'retire mine'"
# Dropping the variable from a re-run must not strand the operator.
SSH_PUBLIC_KEY=""
revoke_prior_ssh_key "$AK" "$st/ssh_public_key"
chk "nothing withdrawn" "$before" "$(cat "$AK")"

echo "38. the predecessor is never withdrawn before the successor is in place"
# An interrupted run must leave two usable keys, never zero.
printf '%s\n' "$OLD" > "$AK"
printf '%s\n' "$OLD" > "$st/ssh_public_key"
SSH_PUBLIC_KEY="$NEW"
revoke_prior_ssh_key "$AK" "$st/ssh_public_key"     # successor not added yet
chk "the old key still lets you in" 1 "$(grep -cxF "$OLD" "$AK")"

echo "39. first run and an already-absent key are no-ops"
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

echo "40. rotating DB_USER moves the tables and retires the old credential"
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

echo "41. an unchanged DB_USER touches nothing"
rotate collavre_user "$d3/db_user"
chk "no SQL" "" "$SQL$LOGGED"

echo "42. a superuser predecessor is reported, never disabled"
# DB_USER=postgres on a first run is legal. NOLOGIN on the cluster superuser
# locks every operator out of administering it — peer auth needs LOGIN too, so
# there is no way back in.
printf 'postgres\n' > "$d3/db_user"
ROLE_IS_SUPER=t
rotate collavre_app "$d3/db_user"
chk "no SQL ran" "" "$SQL"
case "$LOGGED" in
  *"is a superuser"*"by hand"*) echo "  ok   operator is told to finish it by hand" ;;
  *) echo "  FAIL silent: $LOGGED"; fail=1 ;;
esac

echo "43. first run, emptied marker and a dropped role are all no-ops"
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

echo
if [ "$fail" = 0 ]; then echo "ALL PASS"; else echo "FAILURES"; fi
exit "$fail"
