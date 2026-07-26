#!/usr/bin/env bash
#
# Collavre — AWS Lightsail launch script (instance user data).
#
# Paste the contents of this file into the "Launch script" box when creating a
# Lightsail instance (Ubuntu 24.04 LTS blueprint), or run it by hand on a fresh
# instance as root:
#
#   sudo SSH_PUBLIC_KEY="ssh-ed25519 AAAA..." bash script/lightsail_launch.sh
#
# What it does (host preparation only — it never builds or runs the app):
#
#   1. base packages, timezone, swap, SSH hardening
#   2. a deploy user (default: collavre) in the docker group for `kamal`, with
#      passwordless sudo for the maintenance commands in the runbook
#   3. Docker CE + buildx + compose plugins, with log rotation
#   4. PostgreSQL, reachable ONLY from containers on this host
#   5. the collavre_production database + application role (idempotent)
#   6. ufw firewall, nightly pg_dump backups with retention
#
# The app itself is deployed afterwards from your workstation with
# `./kamal.sh setup`, which builds the image and boots the container. See
# docs/deploy_to_lightsail.md for the full runbook.
#
# The script is idempotent: re-running it converges the host instead of
# duplicating configuration. Re-run with FORCE=1 after the first success.
#
set -euo pipefail

# --------------------------------------------------------------------------
# Configuration — edit these before pasting into the Lightsail console.
# Every value can also be supplied as an environment variable.
# --------------------------------------------------------------------------

# Which of the settings below the caller actually asked for, recorded before the
# defaults fill in the rest. Afterwards every one of them is set and the two
# cases are indistinguishable — and the difference is the whole question a
# re-run has to answer. `sudo FORCE=1 bash script/lightsail_launch.sh` on a host
# provisioned with an override reads as "converge this host", but several of
# these settings converge by *rotating*: the deploy user's sudo and docker
# grants move to whatever APP_SSH_USER now says, and table ownership and LOGIN
# move to whatever DB_USER now says. Defaulted back to `collavre` and
# `collavre_user`, that is a rotation nobody asked for, performed against the
# account and role the running deployment authenticates as.
#
# DB_PASSWORD is not in the list: it is already reloaded from $STATE_DIR when
# unset, which is this same idea applied to the one setting that had it.
LAUNCH_SETTINGS='SSH_PUBLIC_KEY APP_SSH_USER PG_MAJOR DB_NAME DB_USER
                 DB_BIND_ADDRESS DOCKER_SUBNETS SWAP_SIZE_MB TIMEZONE
                 INSTANCE_HOSTNAME BACKUP_RETENTION_DAYS BACKUP_S3_URI BACKUP_AT'
SUPPLIED_SETTINGS=''
for _s in $LAUNCH_SETTINGS; do
  [ -n "${!_s+set}" ] && SUPPLIED_SETTINGS="$SUPPLIED_SETTINGS $_s"
done
unset _s

# SSH public key that may log in as the deploy user. Leave empty to reuse the
# key Lightsail installed for the default `ubuntu` user.
: "${SSH_PUBLIC_KEY:=}"

# Deploy user. Must match KAMAL_SSH_USER in .env.production.
: "${APP_SSH_USER:=collavre}"

# PostgreSQL major version (from the PGDG apt repository).
: "${PG_MAJOR:=17}"

# The port the cluster serves. Not really configurable: it is what DATABASE_URL,
# the ufw rule and the nightly backup all name, and a host with a second cluster
# on it is refused rather than half-provisioned (ensure_cluster_on_default_port).
# A constant with a name, so those four places cannot drift apart.
: "${DB_PORT:=5432}"

# Database and role. Defaults match db/setup_postgres_databases.sql.
: "${DB_NAME:=collavre_production}"
: "${DB_USER:=collavre_user}"
# Leave empty to generate a random URL-safe password.
: "${DB_PASSWORD:=}"

# Address PostgreSQL listens on for container traffic. 172.17.0.1 is the
# docker0 bridge gateway: reachable from every container on this host and from
# nowhere else. Do NOT set this to the public or private instance address.
: "${DB_BIND_ADDRESS:=172.17.0.1}"
# Source range allowed to reach that address (all Docker bridge networks).
: "${DOCKER_SUBNETS:=172.16.0.0/12}"

# Swap file size in MiB. Rails asset builds and pg_dump both want headroom on
# small instances. Set to 0 to skip.
: "${SWAP_SIZE_MB:=2048}"

: "${TIMEZONE:=Asia/Seoul}"
: "${INSTANCE_HOSTNAME:=collavre}"

# Nightly backups: local retention in days, and an optional S3 destination
# (e.g. s3://collavre-backups/pg). S3 upload needs AWS credentials in
# /root/.aws/credentials — Lightsail instances have no IAM instance role.
: "${BACKUP_RETENTION_DAYS:=7}"
: "${BACKUP_S3_URI:=}"
: "${BACKUP_AT:=03:30}"

# --------------------------------------------------------------------------
# Internals
# --------------------------------------------------------------------------

STATE_DIR=/var/lib/collavre
MARKER="$STATE_DIR/launch.done"
LOG_FILE=/var/log/collavre-launch.log
SUMMARY=/root/collavre-lightsail-summary.txt

export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a
export NEEDRESTART_SUSPEND=1

mkdir -p "$STATE_DIR"
# Root-only before anything is written to it: this log is a transcript of a
# provisioning run, and cloud-init's own copy of our stdout
# (/var/log/cloud-init-output.log) is readable by more than root. Nothing
# printed below may contain a credential.
touch "$LOG_FILE"
chmod 0600 "$LOG_FILE"
exec > >(tee -a "$LOG_FILE") 2>&1

log() { printf '\n=== [%s] %s\n' "$(date -Is)" "$*"; }
die() { printf '\n!!! [%s] %s\n' "$(date -Is)" "$*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "run as root"

# DB_PORT names the port, it does not choose it. Nothing here writes
# postgresql.conf: the cluster is created by the postgresql-$PG_MAJOR package,
# and pg_createcluster takes the first free port from 5432. So an overridden
# DB_PORT is consumed by psql, the ufw rule, the backup unit and DATABASE_URL
# while the cluster listens on 5432 regardless — and the check that would catch
# a mismatched cluster cannot help on a fresh host, because pg_lsclusters does
# not exist until several steps after this one.
#
# Refused rather than converged, deliberately. Making it work means writing a
# port into postgresql.conf and restarting a cluster this script did not create
# the layout of, which is a bigger promise than the one line of configuration
# suggests. The variable stays, because four places name the port and a literal
# in each of them is how they drift apart.
[ "$DB_PORT" = "5432" ] || die \
  "DB_PORT=$DB_PORT is not supported: this script does not configure the cluster's port," \
  "so PostgreSQL would still listen on 5432 while DATABASE_URL, the ufw rule and the" \
  "nightly backup all named $DB_PORT. Leave DB_PORT unset, and move the cluster by hand" \
  "afterwards if you need a different port."

if [ -f "$MARKER" ] && [ "${FORCE:-0}" != "1" ]; then
  log "already provisioned ($MARKER). Re-run with FORCE=1 to converge again."
  exit 0
fi

# refuse_defaulted_config_change [state dir] [supplied settings]
#
# A re-run applies every setting, not just the ones it was given: an override
# the operator used the first time and did not repeat is applied as its
# default. For most of these that is harmless convergence, but three of them
# are not convergence at all —
#
#   APP_SSH_USER   arms a new account and takes docker + sudo + the sudoers.d
#                  grant back from the one recorded in $STATE_DIR/deploy_user,
#                  which is the account KAMAL_SSH_USER names and deploys with
#   DB_USER        REASSIGN OWNED and NOLOGIN move the application's tables and
#                  its ability to log in to a different role, while the
#                  deployed DATABASE_URL still names the old one
#   BACKUP_S3_URI  regenerates /usr/local/bin/collavre-pg-backup without the
#                  upload, so the nightly dump quietly stops leaving the host
#
# — and the first two are triggered by a bare `FORCE=1` re-run, which is what
# this page and the runbook both advertise. So the question is not what the
# value is, it is whether the run was *asked* for it. A named setting is an
# instruction and goes through, whatever it says; an unnamed one that disagrees
# with the provisioned config is an omission, and is refused before anything
# is installed or rotated.
#
# ACK_CONFIG_RESET=1 accepts the listed defaults for operators who do mean to
# reset them, so the guard is a stop rather than a dead end.
refuse_defaulted_config_change() {
  local state_dir="${1:-$STATE_DIR}" supplied="${2:-$SUPPLIED_SETTINGS}"
  local env_file="$state_dir/launch.env" name prior now drift='' replay='' pair file
  # Which file the operator should read is not the same question on both
  # branches, and the branch that answers it wrong is the one that fires on a
  # host where launch.env does not exist — pointing an operator mid-refusal at
  # an absent file reads as "the record is missing", which is the opposite of
  # what just happened: the comparison was answered, by a different file.
  local record=''

  # Recorded as they are found, so the replay command the refusal prints is
  # built from the same comparison that refused — a second pass over the file
  # could print a line that does not clear the guard it is offered for.
  note_drift() {
    drift="$drift    $1: host has '$2', this run would apply '$3'"$'\n'
    replay="$replay$(printf '%s=%q ' "$1" "$2")"
  }

  if [ -f "$env_file" ]; then
    record="The host's own record of what it was given is $env_file."
    # Driven by the current setting list rather than by the file's lines, so a
    # value this revision no longer has, or a line an editor mangled, cannot be
    # turned into an indirect expansion of an arbitrary name.
    for name in $LAUNCH_SETTINGS; do
      case " $supplied " in *" $name "*) continue ;; esac
      grep -q "^$name=" "$env_file" || continue
      prior="$(sed -n "s/^$name=//p" "$env_file" | head -1)"
      now="${!name}"
      [ "$prior" = "$now" ] && continue
      note_drift "$name" "$prior" "$now"
    done
  else
    # Provisioned before launch.env existed. The two settings that rotate a
    # live credential are still answerable from the state files that predate
    # it, so the upgrade path is covered for the cases that can hurt rather
    # than left open until the next re-run happens to record the defaults.
    for pair in deploy_user:APP_SSH_USER db_user:DB_USER; do
      file="${pair%%:*}"; name="${pair##*:}"
      [ -f "$state_dir/$file" ] || continue
      case " $supplied " in *" $name "*) continue ;; esac
      prior="$(cat "$state_dir/$file")"
      now="${!name}"
      if [ -n "$prior" ] && [ "$prior" != "$now" ]; then
        note_drift "$name" "$prior" "$now"
        # Named as they answer, so the message sends the operator to the file
        # that actually decided this refusal rather than to the whole directory.
        record="$record${record:+, }$state_dir/$file"
      fi
    done
    [ -z "$record" ] || record="This host predates $env_file, so what it was
given is recorded only in $record.
The settings not kept there could not be checked at all — repeating those is
still on you."
  fi
  unset -f note_drift

  [ -n "$drift" ] || return 0
  if [ "${ACK_CONFIG_RESET:-0}" = "1" ]; then
    log "ACK_CONFIG_RESET=1 — applying defaults over the provisioned values:" \
        "$(printf '\n%s' "$drift")"
    return 0
  fi

  # One argument built with ANSI-C newlines rather than several joined by die's
  # own space: the recovery below has to arrive on its own line to be pasted,
  # and $(printf '...\n') cannot put it there — command substitution strips the
  # trailing newline, so the next argument would land on the same line as the
  # command it is meant to follow.
  die "REFUSING: this run would change settings it was not asked to change."$'\n\n'\
"$drift"$'\n'\
"Each of these was chosen when the host was provisioned and is not set on this
run, so the value above is this script's default rather than a decision.
Applied, APP_SSH_USER and DB_USER do not converge the host: they rotate the
deploy account and the database role out from under the running deployment,
whose .env.production still names the old ones."$'\n\n'\
"Nothing has been changed. Repeat them to converge the host as it is:"$'\n\n'\
"    sudo ${replay}FORCE=1 bash script/lightsail_launch.sh"$'\n\n'\
"or set ACK_CONFIG_RESET=1 if you do mean to reset them to the defaults."$'\n'\
"$record"
}

refuse_defaulted_config_change

# cloud-init and unattended-upgrades hold the dpkg lock during early boot;
# DPkg::Lock::Timeout makes apt wait for them instead of failing outright.
APT_OPTS=(-o DPkg::Lock::Timeout=600
          -o Dpkg::Options::=--force-confdef
          -o Dpkg::Options::=--force-confold)

apt_get() { apt-get "${APT_OPTS[@]}" "$@"; }
apt_install() { apt_get install -y --no-install-recommends "$@"; }

# Percent-encode everything outside the RFC 3986 unreserved set, byte by byte
# (LC_ALL=C, so multi-byte characters encode as their UTF-8 bytes). The
# generated password is alphanumeric and passes through untouched; an
# operator-supplied DB_PASSWORD is not, and config/database.yml runs
# URI.parse(ENV["DATABASE_URL"]) at boot, which rejects @ / # % ? and space in
# userinfo outright.
urlencode() {
  local LC_ALL=C s="$1" i c out=''
  for (( i = 0; i < ${#s}; i++ )); do
    c="${s:i:1}"
    case "$c" in
      [A-Za-z0-9._~-]) out="$out$c" ;;
      *) out="$out$(printf '%%%02X' "'$c")" ;;
    esac
  done
  printf '%s' "$out"
}

# Keep a managed block in a config file equal to $content, keyed by a marker.
# Added on the first run; on later runs the body is replaced in place, so a
# FORCE=1 re-run with a changed DOCKER_SUBNETS or INSTANCE_HOSTNAME converges
# the host instead of leaving the previous value in force. In place, not
# delete-and-append: pg_hba.conf is first-match-wins, and moving the rule to
# the end of the file could park it behind one that already rejects.
ensure_block() {
  local file="$1" marker="$2" content="$3"
  local begin="# BEGIN collavre:$marker" end="# END collavre:$marker"

  if ! grep -qF "$begin" "$file" 2>/dev/null; then
    {
      printf '\n%s (managed by script/lightsail_launch.sh)\n' "$begin"
      printf '%s\n' "$content"
      printf '%s\n' "$end"
    } >> "$file"
    return 0
  fi

  grep -qF "$end" "$file" || \
    die "$file: '$begin' with no '$end'. Refusing to rewrite a block I cannot delimit — repair or delete it by hand."

  local tmp
  tmp="$(mktemp)"
  # index() rather than an anchored match, so awk sees exactly the lines the
  # grep above found. END exits non-zero on an unterminated block (END marker
  # before BEGIN), which would otherwise swallow the rest of the file.
  if ! BLOCK_BEGIN="$begin" BLOCK_END="$end" BLOCK_BODY="$content" awk '
      BEGIN { b = ENVIRON["BLOCK_BEGIN"]; e = ENVIRON["BLOCK_END"] }
      !inside && index($0, b) {
        inside = 1
        print b " (managed by script/lightsail_launch.sh)"
        print ENVIRON["BLOCK_BODY"]
        print e
        next
      }
      inside && index($0, e) { inside = 0; next }
      inside { next }
      { print }
      END { if (inside) exit 1 }
    ' "$file" > "$tmp"; then
    rm -f "$tmp"
    die "$file: collavre:$marker block is malformed (END before BEGIN?). Repair it by hand."
  fi

  # Through the existing inode: pg_hba.conf is postgres:postgres 0640, and a
  # mv from mktemp would hand it root:root 0600 and stop PostgreSQL reading it.
  cat "$tmp" > "$file"
  rm -f "$tmp"
}

# Give $1 passwordless sudo, and make sure it is the only deploy user holding
# a grant this script wrote. `usermod -aG sudo` on its own does not work here:
# `adduser --disabled-password` leaves `!` in /etc/shadow and Ubuntu's %sudo
# rule is password-authenticated, so every sudo the runbook sends over ssh
# fails with "a password is required".
#
# NOPASSWD:ALL rather than a command list. This user is already in the docker
# group, which is root-equivalent — `docker run -v /:/host` is a root shell —
# so an allowlist would withhold nothing it does not already have, while
# breaking the next maintenance command someone documents.
ensure_sudoers() {
  local user="$1" dir="${2:-/etc/sudoers.d}" tmp existing
  # sudo's includedir skips any filename that contains '.' or ends in '~', and
  # a Linux username may legally contain a dot.
  local name="90-collavre-${user//[^A-Za-z0-9_-]/_}"

  tmp="$(mktemp)"
  printf '%s ALL=(ALL:ALL) NOPASSWD:ALL\n' "$user" > "$tmp"
  chmod 0440 "$tmp"
  # Validate before installing, never after. A syntax error anywhere under
  # sudoers.d makes sudo refuse to run for *every* user ("no valid sudoers
  # sources found"), and step 3 has just set PermitRootLogin no — there would
  # be no way back into the host.
  if ! visudo -cf "$tmp" >/dev/null 2>&1; then
    rm -f "$tmp"
    die "refusing to install an unparseable sudoers file for '$user'"
  fi
  # Owned by root by construction: this script runs as root (checked above).
  install -m 0440 "$tmp" "$dir/$name"
  rm -f "$tmp"

  # Converge rather than accumulate: a FORCE=1 re-run with a changed
  # APP_SSH_USER must not leave the previous user's grant in force.
  for existing in "$dir"/90-collavre-*; do
    [ -e "$existing" ] || continue
    [ "$existing" = "$dir/$name" ] || rm -f "$existing"
  done
}

# Take the docker group back from the deploy user a FORCE=1 re-run replaced.
#
# ensure_sudoers above already drops the old NOPASSWD file, but on its own that
# revokes the longer road to root and leaves the shorter one open: docker group
# membership is root-equivalent, so an operator rotating APP_SSH_USER away from
# a compromised account would still be handing it a root shell.
#
# The account itself and its authorized_keys are deliberately left alone. This
# runs on a host whose only other way in is the user the same run just created,
# and `deluser` on the wrong guess (APP_SSH_USER=ubuntu on the first run, say)
# is unrecoverable. With both groups gone the keys reach an ordinary account,
# which is a job for a human who can see the host.
in_group() {
  # id -nG rather than `getent group`: it reports the primary group too, and
  # the membership that matters is the effective one either way.
  id -nG "$1" 2>/dev/null | tr ' ' '\n' | grep -qxF "$2"
}

revoke_prior_deploy_user() {
  local current="$1" prior_file="${2:-$STATE_DIR/deploy_user}" prior group held
  [ -f "$prior_file" ] || { printf '%s\n' "$current" > "$prior_file"; return 0; }
  prior="$(cat "$prior_file")"
  if [ -z "$prior" ] || [ "$prior" = "$current" ] ||
     ! id -u "$prior" >/dev/null 2>&1; then
    printf '%s\n' "$current" > "$prior_file"
    return 0
  fi

  for group in docker sudo; do
    in_group "$prior" "$group" || continue
    if [ "$(id -gn "$prior" 2>/dev/null)" = "$group" ]; then
      # gpasswd edits /etc/group only, so it cannot touch a PRIMARY group: it
      # exits 3 with "user is not a member" while `id -nG` goes on reporting
      # the membership. Giving the account a primary group named after itself
      # is what useradd would have done by default, and is the only way to take
      # docker back from one an operator made with `useradd -g docker`.
      groupadd -f "$prior" >/dev/null 2>&1 || true
      usermod -g "$prior" "$prior" >/dev/null 2>&1 || true
    fi
    # A group can be BOTH the primary one and a member entry in /etc/group, and
    # `useradd -g docker` followed by `gpasswd -a` is how it happens. Moving the
    # primary group leaves that /etc/group line behind, so the account keeps the
    # group; re-reading membership is what tells the two cases apart. Guarded so
    # gpasswd is never called on a non-member, whose error would land in the
    # provisioning log operators read for real ones.
    if in_group "$prior" "$group"; then
      gpasswd -d "$prior" "$group" >/dev/null 2>&1 || true
    fi
    # Verify rather than trust an exit status. This is what decides whether the
    # message below is true, and a rotation that merely *claims* to have taken
    # root back is worse than one that admits it could not.
    in_group "$prior" "$group" ||
      log "revoked '$group' from the replaced deploy user '$prior'"
  done

  held=""
  for group in docker sudo; do
    in_group "$prior" "$group" && held="$held $group"
  done
  if [ -n "$held" ]; then
    log "WARNING: could NOT revoke$held from the replaced deploy user '$prior';" \
        "it still has root-equivalent access to this host. Take it back by hand," \
        "both of these — the group can be primary AND a member entry at once:" \
        "usermod -g $prior $prior; for g in$held; do gpasswd -d $prior \$g; done"
    # Deliberately leave the marker naming the user that still holds the group,
    # so the next run retries the revocation instead of forgetting it.
    return 0
  fi

  log "WARNING: '$prior' is no longer in docker or sudo but can still log in;" \
      "remove it by hand once you can reach the host as '$current':" \
      "deluser --remove-home $prior"
  printf '%s\n' "$current" > "$prior_file"
}

# psql_as_postgres <database> <sql>
#
# One place to reach the cluster as the superuser, so the rotation below can be
# exercised in tests by stubbing a single command.
#
# The port is explicit even though 5432 is also the default. Everything this
# script hands out — DATABASE_URL, the ufw rule, the backup timer — names 5432,
# so this is the one place that would otherwise silently disagree with them.
psql_as_postgres() {
  runuser -u postgres -- psql -v ON_ERROR_STOP=1 -qtA -p "$DB_PORT" -d "$1" -c "$2"
}

# Make /swapfile match $SWAP_SIZE_MB, including when that means removing it.
#
# The previous form asked "is swap already on?" and skipped everything if so,
# which converges only the first run: raising SWAP_SIZE_MB after an OOM left the
# old headroom in place, and SWAP_SIZE_MB=0 left swap enabled — both reported as
# a successful convergent run. The size on disk is what has to be compared,
# because that is the thing the setting names.
#
# A resize means swapoff first, and swapoff can fail when the pages cannot be
# faulted back into RAM — the low-memory instance this setting exists for is
# exactly where that happens. That is reported and the old swap left running,
# rather than being fatal: nothing downstream depends on the size, and dying
# here would abandon a provisioning run over the one condition where the
# operator most needs the host to come up.
#
# The same rule decides the other way a resize fails. Growing the file means
# freeing the old one first, so an allocation that does not fit would otherwise
# leave the host with no swap at all — strictly worse than the state the run
# started from. The previous size is restored and the run continues.
ensure_swapfile() {
  local swap="${1:-/swapfile}" fstab="${2:-/etc/fstab}"
  local want="$SWAP_SIZE_MB" have=0 active=no
  swapon --show=NAME --noheadings 2>/dev/null | grep -qxF "$swap" && active=yes
  # GNU stat first; BSD stat rejects -c, and the unit tests run on both.
  [ -f "$swap" ] &&
    have=$(( $(stat -c %s "$swap" 2>/dev/null || stat -f %z "$swap" 2>/dev/null || echo 0) / 1048576 ))

  if [ "$want" -eq "$have" ] && { [ "$want" -eq 0 ] || [ "$active" = yes ]; }; then
    # The file needs no work, but the fstab entry still might. Swap that is
    # active without being in fstab is gone after the next reboot, and this is
    # how a host arrives in that state: an operator who ran `swapon` by hand
    # before provisioning, or an earlier run interrupted between `swapon` and
    # `ensure_block` below. Returning here would report a convergent run over a
    # host that silently loses its headroom on the next restart — and a reboot
    # is precisely when a low-memory instance is most likely to need it.
    # ensure_block is idempotent, so the ordinary re-run is unaffected.
    if [ "$want" -eq 0 ]; then
      # Converge a block that is already there — an operator who deleted the
      # swapfile by hand leaves the fstab line behind, and that line fails the
      # next boot's mount. Do not *create* an empty managed block on a host that
      # never had swap and is not asking for any.
      if grep -qF '# BEGIN collavre:swap' "$fstab" 2>/dev/null; then
        ensure_block "$fstab" swap ""
      fi
    else
      ensure_block "$fstab" swap "$swap none swap sw 0 0"
    fi
    return 0
  fi

  if [ "$active" = yes ] && ! swapoff "$swap" 2>/dev/null; then
    # Keeping the old swap is the point of this branch, so it has to be kept
    # across a reboot too. Skipping ensure_block here left the resize failing
    # *twice*: the size did not change, and the swap that was retained instead
    # was retained only until the next restart. The fstab line names the path
    # and not the size, so it is the same line whichever size survives.
    ensure_block "$fstab" swap "$swap none swap sw 0 0"
    log "WARNING: could not swapoff $swap (${have}MiB), so it is unchanged;" \
        "SWAP_SIZE_MB=$want did NOT take effect. Free some memory and re-run," \
        "or resize it by hand."
    return 0
  fi

  if [ "$want" -eq 0 ]; then
    rm -f "$swap"
    # An empty managed block rather than a deletion: ensure_block owns these
    # lines by marker, and leaving the marker in place keeps a later re-run with
    # a non-zero size converging the same block instead of appending a second.
    ensure_block "$fstab" swap ""
    log "swap disabled (SWAP_SIZE_MB=0)"
    return 0
  fi

  rm -f "$swap"
  if ! allocate_swapfile "$swap" "$want"; then
    # The new size did not fit. Put back what was there rather than leaving the
    # host with none: the operator raising SWAP_SIZE_MB is doing so under memory
    # pressure, and a run that answers by taking away the swap they already had
    # makes exactly the condition it was called about worse. The old size is
    # known to fit — its space was freed a moment ago — and a swapfile's
    # contents are dead once swapoff has faulted the pages back, so recreating
    # it is a restore and not an approximation of one.
    rm -f "$swap"
    if [ "$have" -gt 0 ] && allocate_swapfile "$swap" "$have"; then
      swapon "$swap"
      # Same reasoning as the swapoff branch above: what is put back has to
      # survive a reboot, or the restore lasts until the next restart.
      ensure_block "$fstab" swap "$swap none swap sw 0 0"
      log "WARNING: could not allocate ${want}MiB for $swap — not enough free disk." \
          "SWAP_SIZE_MB=$want did NOT take effect; the previous ${have}MiB swap is back." \
          "Grow the disk, or lower SWAP_SIZE_MB, and re-run."
      return 0
    fi
    rm -f "$swap"
    die "could not allocate ${want}MiB for $swap and could not restore the previous" \
        "${have}MiB either — this host now has no swap. Free some disk and re-run."
  fi
  swapon "$swap"
  ensure_block "$fstab" swap "$swap none swap sw 0 0"
  [ "$have" -eq 0 ] || log "resized $swap from ${have}MiB to ${want}MiB"
}

# fallocate where the filesystem supports it, dd otherwise. Returns non-zero
# without leaving a partial file behind, so the caller can decide what to do
# rather than inheriting a truncated swapfile at the live path.
allocate_swapfile() {
  local path="$1" mib="$2"
  if ! { fallocate -l "${mib}M" "$path" 2>/dev/null || \
         dd if=/dev/zero of="$path" bs=1M count="$mib" status=none 2>/dev/null; }; then
    rm -f "$path"
    return 1
  fi
  chmod 600 "$path"
  mkswap "$path" >/dev/null
}

# Make sure container logs are capped, whether or not this host already has a
# /etc/docker/daemon.json. Sets DAEMON_JSON_CHANGED to 1 when it changed the
# file, so the caller knows a restart is needed for it to take effect.
#
# A global rather than an echoed value: log() writes to stdout, so a caller
# using $(...) would capture the warnings below along with the flag and then
# compare that to an integer.
#
# The previous form only wrote the file when it was absent. On the by-hand path
# the runbook documents — an existing instance, Docker already installed,
# possibly with an operator's own daemon.json — the caps were silently skipped
# while the run reported Docker as configured. json-file with no `max-size` does
# not rotate at all, so sustained Rails output fills a Lightsail SSD, which is
# the specific failure this block exists to prevent.
ensure_docker_log_caps() {
  local file="${1:-/etc/docker/daemon.json}" tmp driver
  DAEMON_JSON_CHANGED=0

  if [ ! -f "$file" ]; then
    # Indented so no line of the body starts at column 1: the unit tests extract
    # these functions with an awk range that ends at the first column-1 "}", and
    # a bare closing brace in a heredoc would cut the function in half.
    cat > "$file" <<'JSON'
    {
      "log-driver": "json-file",
      "log-opts": { "max-size": "10m", "max-file": "3" }
    }
JSON
    DAEMON_JSON_CHANGED=1
    return 0
  fi

  if ! jq empty "$file" >/dev/null 2>&1; then
    log "WARNING: $file is not valid JSON, so the container log caps were NOT" \
        "applied and Docker will not start until it is repaired. Left untouched" \
        "rather than overwritten — it is not this script's file."
    return 0
  fi

  # Only json-file is unbounded by default. journald, local and the cloud
  # drivers do their own rotation, and forcing json-file onto a host whose
  # operator chose otherwise would redirect their logs, not cap them.
  driver="$(jq -r '."log-driver" // "json-file"' "$file")"
  if [ "$driver" != "json-file" ]; then
    log "docker log-driver is '$driver', which rotates on its own;" \
        "leaving $file alone"
    return 0
  fi

  if [ "$(jq -r '."log-opts"."max-size" // empty' "$file")" != "" ]; then
    return 0
  fi

  tmp="$(mktemp)"
  # Merge rather than replace: everything else in the file is the operator's.
  # Validated before it is installed, because a daemon.json that does not parse
  # stops Docker from starting at all.
  if ! jq '."log-driver" = "json-file"
           | ."log-opts" = ((."log-opts" // {})
               + {"max-size": "10m", "max-file": "3"})' "$file" > "$tmp" ||
     ! jq empty "$tmp" >/dev/null 2>&1; then
    rm -f "$tmp"
    log "WARNING: could not merge the log caps into $file; it is unchanged and" \
        "container logs are NOT capped. Add" \
        '"log-opts": {"max-size": "10m", "max-file": "3"} by hand.'
    return 0
  fi
  cat "$tmp" > "$file"
  rm -f "$tmp"
  log "added container log caps to the existing $file"
  DAEMON_JSON_CHANGED=1
}

# Refuse to provision when $PG_MAJOR's cluster is not the one on $DB_PORT.
#
# This script assumes one cluster, on the default port: DATABASE_URL, the ufw
# rule and the nightly pg_dump all hard-code 5432. Ubuntu's postgresql-common
# does not share that assumption — pg_createcluster allocates the first free
# port starting at 5432, so installing a second major version puts it on 5433.
#
# The run would then edit /etc/postgresql/$PG_MAJOR/main (tuning, listen_addresses,
# the pg_hba rule for the docker bridge) while `psql` — and therefore the database,
# the role, the backups and the DATABASE_URL — kept talking to whatever answers on
# 5432. A FORCE=1 re-run with a bumped PG_MAJOR is the case that hurts: the app and
# its backups stay on the old cluster, the log says the new version, and the new
# cluster sits empty holding a quarter of RAM in shared_buffers. Nothing fails.
#
# Migrating between clusters is pg_upgradecluster's job and needs a human to
# decide when the app stops, so this aborts and says so rather than guessing.
ensure_cluster_on_default_port() {
  local lsclusters="${1:-pg_lsclusters}" ver port owner_of_default=""
  command -v "$lsclusters" >/dev/null 2>&1 || return 0

  while read -r ver _cluster port _rest; do
    [ -n "$ver" ] || continue
    [ "$port" = "$DB_PORT" ] && owner_of_default="$ver"
    if [ "$ver" = "$PG_MAJOR" ] && [ "$port" != "$DB_PORT" ]; then
      die "PostgreSQL $PG_MAJOR is installed but its 'main' cluster listens on $port, not $DB_PORT." \
          "This script only supports a single cluster on $DB_PORT — DATABASE_URL, the ufw rule" \
          "and the nightly backup all name it. Move it with 'pg_ctlcluster' /" \
          "'/etc/postgresql/$PG_MAJOR/main/postgresql.conf', or set PG_MAJOR to the version" \
          "already serving $DB_PORT."
    fi
  done <<EOF
$("$lsclusters" -h 2>/dev/null)
EOF

  if [ -n "$owner_of_default" ] && [ "$owner_of_default" != "$PG_MAJOR" ]; then
    die "PostgreSQL $owner_of_default already serves $DB_PORT on this host, and PG_MAJOR is $PG_MAJOR." \
        "Installing $PG_MAJOR now would create its cluster on the next free port while the app," \
        "the backups and DATABASE_URL kept using $DB_PORT — a version bump that silently does not" \
        "happen. Either set PG_MAJOR=$owner_of_default, or migrate deliberately with" \
        "'pg_upgradecluster $owner_of_default main' and drop the old cluster before re-running."
  fi
}

# reassign_prior_db_role <current> [state file]
#
# The deploy-user counterpart of revoke_prior_deploy_user, for the same reason:
# a re-run that changes DB_USER creates the new role and moves the *database*
# owner to it, but every table and sequence the app already created stays owned
# by the old role. The new role is then handed out in DATABASE_URL and cannot
# read its own tables — "permission denied for table users" on the first query
# after a rotation that reported success. Meanwhile the old role keeps LOGIN and
# the very same password out of $STATE_DIR/db_password, so a rotation intended
# to retire a credential retires nothing.
#
# REASSIGN OWNED moves ownership of everything the old role owns in this
# database in one statement, including objects added since. It is a no-op when
# the role owns nothing, so it is safe on a host where the app never booted.
# Refuse a rotation away from a superuser predecessor, before the database SQL
# runs and therefore before anything has moved.
#
# The earlier form let this case through with a warning, which was worse than it
# looked. The caller's SQL had already run ALTER DATABASE ... OWNER TO the new
# role by then, so the run went on to record the new DB_USER and publish a
# DATABASE_URL naming a role that owns the database and not one table in it —
# 'permission denied for table users' on the app's first query — while the
# advanced marker meant no later run would ever look at the old role again.
#
# It cannot be converged here. REASSIGN OWNED BY the bootstrap superuser is
# rejected by PostgreSQL outright ("required by the database system"), and
# enumerating the objects instead is the fragile thing this function exists to
# avoid: whatever relkind the enumeration forgets comes back as the same
# permission error, later and on one table rather than all of them. So the run
# stops with nothing changed, the marker still naming the old role, and the
# runbook carries the transfer to do by hand.
# role_owns_app_objects <db> <role>
#
# How many application objects in <db> that role still owns: tables, partitioned
# tables, sequences, views and materialized views, outside the system schemas.
# Exactly the set the runbook's by-hand transfer moves, and exactly the set whose
# ownership decides whether the app can read its own data.
#
# Indexes and TOAST tables are excluded deliberately rather than by accident.
# They cannot be reassigned on their own — they follow the table they belong to
# — and pg_toast is not one of the two schemas the obvious exclusion list names,
# so a query written without the relkind filter reports dozens of catalog TOAST
# tables owned by postgres on every host and can never come back empty. That is
# not a hypothetical: it is what the runbook's own verification query did, which
# is why the operator could not confirm a transfer either.
#
# Prints the count, or nothing if the query could not run — the caller must
# treat that as "still owns objects" rather than as zero. A rotation is refused
# on the strength of this number, so an unanswerable question has to read as the
# unsafe answer.
role_owns_app_objects() {
  psql_as_postgres "$1" \
    "SELECT count(*) FROM pg_class c
       JOIN pg_namespace n ON n.oid = c.relnamespace
      WHERE n.nspname NOT IN ('pg_catalog', 'information_schema', 'pg_toast')
        AND c.relkind IN ('r', 'p', 'S', 'v', 'm')
        AND pg_get_userbyid(c.relowner) = '$2'"
}

refuse_superuser_db_rotation() {
  local current="$1" prior_file="${2:-$STATE_DIR/db_user}" prior owns
  [ -f "$prior_file" ] || return 0
  prior="$(cat "$prior_file")"
  [ -n "$prior" ] && [ "$prior" != "$current" ] || return 0
  [ "$(psql_as_postgres postgres \
        "SELECT count(*) FROM pg_roles WHERE rolname = '$prior'")" = 1 ] || return 0
  [ "$(psql_as_postgres postgres \
        "SELECT rolsuper FROM pg_roles WHERE rolname = '$prior'")" = t ] || return 0

  # A superuser predecessor that owns nothing has already been transferred by
  # hand, and the rotation it was blocking is now the thing that finishes the
  # job. Blocking on rolsuper alone made the runbook's recovery unreachable:
  # the recipe leaves 'postgres' a superuser on purpose — NOLOGIN on the
  # bootstrap role is a lockout, not a revocation — so the guard fired again on
  # the very re-run it had asked for, with a message claiming objects are owned
  # by a role that no longer owns any. There was no way out of that state except
  # abandoning the rotation.
  owns="$(role_owns_app_objects "$DB_NAME" "$prior")"
  if [ "$owns" = 0 ]; then
    log "previous DB_USER '$prior' is a superuser but owns nothing in '$DB_NAME'," \
        "so the transfer to '$current' has already been done by hand; continuing." \
        "NOTE: '$prior' keeps LOGIN and its password — unlike an ordinary" \
        "rotation, this one does not retire the old credential, and only you can" \
        "decide what should happen to a superuser login."
    return 0
  fi

  # Anything other than a plain 0 — a count, or an empty string from a database
  # that does not exist yet or a query that failed — refuses.
  die "this host was provisioned with DB_USER='$prior', which is a superuser, and" \
      "DB_USER is now '$current'. ${owns:-An unknown number of} object(s) in" \
      "'$DB_NAME' are still owned by '$prior', and PostgreSQL refuses to reassign a" \
      "superuser's objects, so '$current' would own the database and be unable to" \
      "read a row of it. Nothing has been changed. Move the objects by hand — see" \
      "'Changing DB_USER on a re-run' in docs/deploy_to_lightsail.md — then re-run," \
      "or set DB_USER='$prior' to leave the rotation undone."
}

reassign_prior_db_role() {
  local current="$1" prior_file="${2:-$STATE_DIR/db_user}" prior
  [ -f "$prior_file" ] || return 0
  prior="$(cat "$prior_file")"
  [ -n "$prior" ] && [ "$prior" != "$current" ] || return 0
  [ "$(psql_as_postgres postgres \
        "SELECT count(*) FROM pg_roles WHERE rolname = '$prior'")" = 1 ] || return 0

  # A superuser predecessor reaches here only on the path refuse_superuser_db_
  # rotation() lets through: the by-hand transfer is done and there is nothing
  # left to move. Both statements below have to be skipped rather than merely
  # allowed to no-op.
  #
  # REASSIGN OWNED BY the bootstrap superuser is rejected outright — "required
  # by the database system" — whether or not it owns anything in this database,
  # so it is not a no-op, it is an error that would end the run at the last step
  # of a rotation that had otherwise succeeded.
  #
  # And ALTER ROLE postgres NOLOGIN succeeds. That is the dangerous one: nothing
  # in PostgreSQL stops it, the next connection is refused with
  # 'FATAL: role "postgres" is not permitted to log in', and peer authentication
  # needs LOGIN too — so the account you would use to undo it is the account it
  # locks out. Verified on 17 rather than assumed from the docs.
  if [ "$(psql_as_postgres postgres \
            "SELECT rolsuper FROM pg_roles WHERE rolname = '$prior'")" = t ]; then
    if [ "$(role_owns_app_objects "$DB_NAME" "$prior")" = 0 ]; then
      log "left the superuser role '$prior' alone: it owns nothing in '$DB_NAME'," \
          "and taking LOGIN from the cluster superuser locks the host's operators" \
          "out of administering it"
      return 0
    fi
    # Only reachable if the guard was bypassed; failing with the reason beats
    # failing with a raw SQL error.
    die "previous DB_USER '$prior' is a superuser; its objects cannot be reassigned." \
        "See 'Changing DB_USER on a re-run' in docs/deploy_to_lightsail.md."
  fi

  psql_as_postgres "$DB_NAME" "REASSIGN OWNED BY \"$prior\" TO \"$current\""
  log "moved ownership of everything in '$DB_NAME' from '$prior' to '$current'"
  psql_as_postgres postgres "ALTER ROLE \"$prior\" NOLOGIN"
  log "revoked LOGIN from the replaced database role '$prior'"
}

# refuse_db_name_change <name> [state dir]
#
# DB_NAME is the one identifier a re-run could change with no trace at all. The
# create-if-missing SQL below simply makes a second, empty database; nothing
# renames or migrates the first, and until now nothing recorded which one a
# previous run had chosen. Measured on postgres:17 against a host holding 5,000
# rows, re-running with a mistyped name:
#
#   run reports success
#   databases: collavre_prod, collavre_production
#   tables in the new one the URL and backup will name : 0
#   rows in the real one, now referenced by nothing    : 5000
#
# So the app boots empty and the nightly pg_dump starts backing up the empty
# one — the live data is not lost, but nothing points at it and nothing is
# protecting it any more. Both halves are silent.
#
# Refused rather than converged, on the same grounds as DB_PORT: renaming is
# ALTER DATABASE ... RENAME TO, which needs no other session connected and
# would strand the already-deployed DATABASE_URL mid-flight, and "migrate" means
# a dump and restore whose timing is the operator's call, not a launch script's.
refuse_db_name_change() {
  local current="$1" state_dir="${2:-$STATE_DIR}" prior others

  if [ -f "$state_dir/db_name" ]; then
    prior="$(cat "$state_dir/db_name")"
    [ -n "$prior" ] && [ "$prior" != "$current" ] || return 0
    die "this host was provisioned with DB_NAME='$prior', and DB_NAME is now" \
        "'$current'. This script creates a database if it is missing; it does not" \
        "rename or copy one, so '$current' would be created empty while the app's" \
        "data stayed in '$prior' — and the summary, DATABASE_URL and the nightly" \
        "backup would all name the empty one. Nothing has been changed. Set" \
        "DB_NAME='$prior', or move the data deliberately — see 'Changing DB_NAME" \
        "on a re-run' in docs/deploy_to_lightsail.md."
  fi

  # No record. On a genuine first run there is nothing to protect, and adopting
  # the name is right. On a host provisioned by a revision that did not track it
  # there is: db_user is the marker that says this script has run here before.
  [ -f "$state_dir/db_user" ] || return 0
  [ "$(psql_as_postgres postgres \
        "SELECT count(*) FROM pg_database WHERE datname = '$current'")" = 0 ] || return 0

  # Previously provisioned, and the database this run names does not exist. That
  # is the change this function exists to stop, arriving on a host too old to
  # have left a record of it.
  others="$(psql_as_postgres postgres \
    "SELECT string_agg(datname, ', ' ORDER BY datname) FROM pg_database
      WHERE datistemplate = false AND datname <> 'postgres'")"
  die "this host has been provisioned before, but DB_NAME='$current' does not" \
      "exist on it. An earlier revision did not record the name it used, so this" \
      "run cannot tell a corrected typo from a rename — and creating '$current'" \
      "would leave the app pointed at an empty database. Databases present:" \
      "${others:-(none)}. Nothing has been changed. Re-run with DB_NAME set to the" \
      "one you mean; it will be recorded from then on."
}

# ensure_ufw_rule <name> <rule> [state file]
#
# Converge one ufw rule the way ensure_block converges one config stanza:
# withdraw what a previous run authorized, then authorize the current value.
# ufw already skips re-adding an identical rule, so this exists for the rule
# whose *value* moves between runs — change DOCKER_SUBNETS or DB_BIND_ADDRESS
# and without it the host would simply accumulate both, leaving the old subnet
# reaching 5432 forever. Recorded rather than parsed back out of `ufw status`,
# whose display form ("172.17.0.1 5432/tcp ALLOW IN 172.17.0.0/16") is not the
# syntax `ufw delete` takes.
ensure_ufw_rule() {
  local name="$1" rule="$2" state="${3:-$STATE_DIR/ufw_$1}" prior=""
  [ -f "$state" ] && prior="$(cat "$state")"

  # The replacement goes in first, so an interrupted run never leaves the host
  # with neither rule. Same ordering as the deploy-user and SSH-key revocations.
  # Unquoted on purpose: a rule is a word list, not one argument.
  # shellcheck disable=SC2086
  ufw $rule >/dev/null

  if [ -n "$prior" ] && [ "$prior" != "$rule" ]; then
    # `ufw delete` exits 0 both when it removed the rule and when there was
    # nothing to remove ("Could not delete non-existent rule"), so a zero status
    # does mean the rule is gone afterwards. It exits non-zero when it could not
    # act at all — unparseable rule text, a lock it could not take — and that is
    # the case where the old rule is still installed.
    #
    # The marker is NOT advanced then. Advancing it would drop the only record
    # of what is still in force: for the postgres rule that means the previous
    # Docker subnet keeps reaching the database for the life of the instance,
    # and no later run can find it to revoke. Leaving the marker makes the next
    # run retry, and `ufw` ignores a re-add of the rule already present.
    # shellcheck disable=SC2086
    if ! ufw delete $prior >/dev/null 2>&1; then
      log "WARNING: could NOT withdraw the previous $name rule, and it is still" \
          "in force: $prior — the marker is left unchanged so the next run" \
          "retries it. Remove it by hand with: ufw delete $prior"
      return 0
    fi
    log "withdrew the previous $name rule: $prior"
  fi

  printf '%s\n' "$rule" > "$state"
}

# True when some rule already authorizes SSH, however narrowly. `ufw allow
# OpenSSH` renders as either "22/tcp" or "OpenSSH" depending on whether the app
# profile is installed, and IPv6 duplicates append " (v6)".
#
# LIMIT counts as authorization, not just ALLOW. `ufw limit` is the rate-limited
# form of an allow rule — it is what ufw's own documentation recommends for SSH
# — and it renders in the Action column as "LIMIT" (some versions "LIMIT IN").
# Reading only ALLOW means an operator who wrote `ufw limit from <ip> to any
# port 22` is told nothing authorizes SSH, and gets a blanket rule added beside
# their restriction, opening 22 to every source they excluded.
#
# The port is not always the first thing on the line. A rule written against a
# particular destination address — `ufw allow from <ip> to <this-host> port 22`,
# which is how SSH gets pinned to one interface on a host with both a public and
# a private address — renders as "10.1.2.3 22/tcp", so anchoring on the port
# misses it and broadens exactly the rule it was meant to respect. Hence the
# optional leading token. It cannot swallow a different port: "2222/tcp" and
# "10.1.2.3 2222/tcp" both still fail to match, as does a host address that
# merely starts with 22 ("22.1.1.1 80/tcp").
#
# Deliberately positive: it answers "is 22 open?", never "is 22 closed?". An
# empty or unparseable `ufw status` therefore means we add the rule, because
# guessing wrong in that direction only re-opens SSH, while guessing wrong in
# the other enables a deny-by-default firewall on a host with no way in.
#
# That same direction is why an all-ports rule ("Anywhere ALLOW <ip>", from
# `ufw allow from <ip>` with no port) is deliberately NOT counted, even though
# it does permit 22 from that source. Its source is some host the operator
# trusts for an unrelated service as often as it is their own workstation, and
# reading it as "SSH is handled" would enable a deny-by-default firewall on a
# box the operator may have no remaining way into. A rule that names port 22 is
# evidence about SSH; one that names no port at all is not.
# IPv6 lines are dropped before the match, and that stage is load-bearing. What
# has to be true here is that *IPv4* port 22 is reachable: `ufw --force enable`
# below applies `default deny incoming`, and an operator reaching a Lightsail
# instance does so over its IPv4 address. ufw prints the address family only as
# a "(v6)" tag on the rule, so a host carrying nothing but
# "22/tcp (v6) ... ALLOW" would otherwise read as authorized — the IPv4 rule
# skipped, and the firewall then enabled against the connection in use.
# Dual-stack hosts are unaffected: `ufw allow OpenSSH` writes both lines, and
# the IPv4 one survives the filter.
#
# The "(v6)" tag alone is not enough to find them, and neither is the leading
# token. ufw only tags a rule that names no address at all ("22/tcp (v6)"); one
# written against an IPv6 *destination* renders untagged as
# "2001:db8::1 22/tcp ALLOW ...", and one restricted to an IPv6 *source* renders
# as "22/tcp ALLOW 2001:db8::9" — untagged, and with an ordinary IPv4-looking
# first column. That last form is the one to keep in mind: narrowing SSH to your
# own address is the most likely reason a host has an IPv6-only rule in the
# first place. So the family is decided by a colon anywhere in the rule, which
# is the only thing all three have in common.
#
# The comment is stripped first because `ufw allow 22/tcp comment 'ssh: admin'`
# puts an operator's colon on an IPv4 line. Failing that way is safe — it adds a
# blanket rule rather than locking anyone out — but it would broaden the very
# rule this function exists to leave alone.
#
# All of it verified against real ufw on ubuntu:24.04, against `iptables -S` as
# the ground truth for whether IPv4 port 22 is actually reachable, rather than
# reasoned about from the rendering.
ssh_already_allowed() {
  ufw status 2>/dev/null |
    sed 's/#.*//' |
    grep -vE '\(v6\)|:' |
    grep -qE '^([^[:space:]]+[[:space:]]+)?(22|OpenSSH)([/[:space:]]).*(ALLOW|LIMIT)'
}

# Authorize SSH, but only if nothing else already does. An operator who
# narrowed 22 to one source address is exactly who this protects: re-adding the
# blanket rule on a re-run would quietly undo that and look like a no-op.
ensure_ssh_rule() {
  if ssh_already_allowed; then
    log "port 22 is already allowed; leaving the existing SSH rule alone"
    return 0
  fi
  # The named form needs the app profile openssh-server installs. Lightsail's
  # Ubuntu images have it, but a minimal one does not, and there `ufw allow
  # OpenSSH` exits 1 — leaving the `ufw --force enable` that follows to close 22
  # on a host whose only way in is 22. The port form needs nothing installed.
  #
  # ufw's own "Could not find a profile" goes to /dev/null and is replaced by
  # the line below: it is a handled condition, and a provisioning log operators
  # scan for real errors should not carry one that was recovered from.
  ufw allow OpenSSH 2>/dev/null || {
    log "no OpenSSH ufw profile on this host; allowing 22/tcp directly"
    ufw allow 22/tcp
  }
}

# --------------------------------------------------------------------------
log "1/9 base packages"
# --------------------------------------------------------------------------
apt_get update -y
apt_get upgrade -y
apt_install ca-certificates curl gnupg git ufw unattended-upgrades \
  acl jq unzip rsync openssl

timedatectl set-timezone "$TIMEZONE"
hostnamectl set-hostname "$INSTANCE_HOSTNAME"
ensure_block /etc/hosts hostname "127.0.1.1 $INSTANCE_HOSTNAME"
dpkg-reconfigure -f noninteractive unattended-upgrades

# --------------------------------------------------------------------------
log "2/9 swap (${SWAP_SIZE_MB}MiB)"
# --------------------------------------------------------------------------
ensure_swapfile
cat > /etc/sysctl.d/99-collavre.conf <<'SYSCTL'
# Prefer RAM, use swap only under real pressure.
vm.swappiness = 10
vm.vfs_cache_pressure = 50
# Let PostgreSQL bind the docker0 gateway address even when the bridge has not
# been created yet (PostgreSQL can start before dockerd after a reboot).
net.ipv4.ip_nonlocal_bind = 1
SYSCTL
sysctl --system >/dev/null

# --------------------------------------------------------------------------
log "3/9 SSH hardening + deploy user '$APP_SSH_USER'"
# --------------------------------------------------------------------------
install -d -m 0755 /etc/ssh/sshd_config.d
cat > /etc/ssh/sshd_config.d/99-collavre.conf <<'SSHD'
PasswordAuthentication no
PermitRootLogin no
KbdInteractiveAuthentication no
SSHD
# Ubuntu ships `Include /etc/ssh/sshd_config.d/*.conf` at the top of
# sshd_config; without it the drop-in above is silently ignored.
grep -q '^Include /etc/ssh/sshd_config.d/' /etc/ssh/sshd_config 2>/dev/null || \
  log "WARNING: sshd_config has no Include for sshd_config.d — harden SSH by hand"
systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null || true

# install_deploy_ssh_dir <user> <home> — create <home>/.ssh owned by the
# account, and echo the group it was given.
#
# The group is asked for, not assumed. adduser creates one named after the user,
# but APP_SSH_USER is allowed to name an account that already exists — the cloud
# user, or one an operator made with `useradd -g users deploybot` — and then
# there is no group of that name. `install` and `chown` reject an unknown group,
# so guessing ends the run here under `set -e`, before authorized keys, Docker
# and PostgreSQL are configured. `id -gn` answers for both cases.
install_deploy_ssh_dir() {
  local user="$1" home="$2" group
  group="$(id -gn "$user")"
  # Explicitly, rather than leaving it to `set -e` inside the command
  # substitution the caller wraps this in: the last command here is a printf
  # that always succeeds, so a swallowed failure would hand back a group name
  # for a directory that was never created.
  install -d -m 0700 -o "$user" -g "$group" "$home/.ssh" || return 1
  printf '%s\n' "$group"
}

# passwd_home <user> [passwd table]
#
# The home directory of an account, or nothing when there is no such account.
# The optional second argument lets the tests supply a passwd table instead of
# the host's.
passwd_home() {
  local user="$1" src="${2:-}"
  if [ -n "$src" ]; then
    awk -F: -v u="$user" '$1 == u { print $6; exit }' "$src"
  else
    # An account that does not exist is an answer here, not an error. `getent`
    # exits 2 for it, and under `pipefail` that status would take the whole run
    # down at the caller's plain assignment — with no message, since neither
    # branch of this function is reached. The awk branch above already reports a
    # missing account as empty output, so this one has to agree with it.
    getent passwd "$user" | cut -d: -f6 || true
  fi
}

# ssh_key_holder <key> [passwd table]
#
# The first account whose authorized_keys contains this key byte-for-byte, or
# nothing. This is the only surviving evidence of who a key belongs to, which
# is what the caller below needs and does not otherwise have.
ssh_key_holder() {
  local key="$1" src="${2:-}" user home tbl rc=1
  tbl="$(mktemp)"
  if [ -n "$src" ]; then cat "$src" > "$tbl"; else getent passwd > "$tbl"; fi
  while IFS=: read -r user _ _ _ _ home _; do
    [ -n "$home" ] && [ -f "$home/.ssh/authorized_keys" ] || continue
    if grep -qxF "$key" "$home/.ssh/authorized_keys" 2>/dev/null; then
      printf '%s\n' "$user"
      rc=0
      break
    fi
  done < "$tbl"
  rm -f "$tbl"
  return "$rc"
}

# adopt_legacy_ssh_key_marker <user> [state dir] [passwd table]
#
# An earlier revision recorded the key it installed in one file per host rather
# than one per account. This re-files that record so the per-account withdrawal
# can still find it — but it must work out *whose* it is, and the account named
# by APP_SSH_USER today is not the answer.
#
# On a host that rotated collavre/key-A to deploybot/key-B under that revision,
# the marker holds B and collavre's authorized_keys still holds A: the old code
# looked for A in deploybot's file, did not find it, and advanced the marker
# anyway. Assigning B to whichever account this run happens to name turns that
# into a privilege escalation. A run that switches back to collavre/key-C files
# B as collavre's predecessor, fails to find B in collavre's file, records C —
# and key-A stays authorized on an account this same run puts back in sudoers
# and the docker group. A key retired two rotations ago is root again, and the
# marker that would have named B for deploybot has been consumed, so B is
# unwithdrawable too. Both halves are silent.
#
# So the marker is adopted only where authorized_keys agrees it belongs, and
# where it does not, ownership is preserved rather than invented. What cannot
# be recovered is key-A: no per-account record of it was ever written, and
# nothing distinguishes it from a key the operator installed themselves. That
# is why the ambiguous case stops the run instead of warning — it stops it
# before usermod and ensure_sudoers below, which are what make the difference
# between an old key sitting in a file and an old key holding root.
adopt_legacy_ssh_key_marker() {
  local user="$1" state_dir="${2:-$STATE_DIR}" src="${3:-}"
  local legacy mine key owner home auth_keys=""
  legacy="$state_dir/ssh_public_key"
  mine="$state_dir/ssh_public_key.$user"
  [ -f "$legacy" ] && [ ! -f "$mine" ] || return 0

  key="$(cat "$legacy")"
  # A marker with nothing in it names no key and can strand the branch forever.
  [ -n "$key" ] || { rm -f "$legacy"; return 0; }

  home="$(passwd_home "$user" "$src")"
  [ -z "$home" ] || auth_keys="$home/.ssh/authorized_keys"

  # Verifiably this account's — the ordinary upgrade, and the case the adoption
  # exists for. Checked directly rather than through the search below so the
  # common path does not depend on reading every account on the host.
  if [ -n "$auth_keys" ] && grep -qxF "$key" "$auth_keys" 2>/dev/null; then
    mv "$legacy" "$mine"
    return 0
  fi

  owner="$(ssh_key_holder "$key" "$src")" || owner=""

  # Authorized for nobody: the key it names is already gone, so the record
  # describes nothing and assigning it to an account would invent a predecessor
  # that no longer exists.
  if [ -z "$owner" ]; then
    rm -f "$legacy"
    log "the SSH key recorded by an earlier revision is no longer authorized for" \
        "any account on this host, so the record was dropped rather than filed" \
        "against '$user'"
    return 0
  fi

  # Verifiably another account's. File it there, so that account's own key stays
  # withdrawable by a later run naming it.
  #
  # An account with no keys of its own cannot be hiding a managed one, so there
  # is nothing to stop the run for; this is also the first-run-creates-the-user
  # path, where the account does not exist yet.
  if [ -z "$auth_keys" ] || [ ! -s "$auth_keys" ]; then
    mv "$legacy" "$state_dir/ssh_public_key.$owner"
    log "the SSH key recorded by an earlier revision belongs to '$owner', not to" \
        "'$user'; filed it against '$owner'"
    return 0
  fi

  if [ -n "${ACK_UNATTRIBUTED_SSH_KEYS:-}" ]; then
    mv "$legacy" "$state_dir/ssh_public_key.$owner"
    log "ACK_UNATTRIBUTED_SSH_KEYS is set: filed the earlier revision's record" \
        "against '$owner', and proceeding with '$user' unchecked — the keys in" \
        "$auth_keys are the operator's responsibility"
    return 0
  fi

  die "this host rotated deploy accounts under an earlier revision of this" \
      "script: the key it recorded is authorized for '$owner', not for" \
      "'$user', which this run names. That revision kept only one record per" \
      "host, so if it ever installed a key for '$user' there is nothing left" \
      "that says which of the keys in $auth_keys it was — and this run is" \
      "about to give '$user' passwordless sudo and the docker socket again." \
      "Nothing has been changed. Read $auth_keys, remove any key you do not" \
      "recognise, then re-run with ACK_UNATTRIBUTED_SSH_KEYS=1 to continue."
}

adopt_legacy_ssh_key_marker "$APP_SSH_USER"

if ! id -u "$APP_SSH_USER" >/dev/null 2>&1; then
  adduser --disabled-password --gecos "Collavre deploy" "$APP_SSH_USER"
fi
usermod -aG sudo "$APP_SSH_USER"
install -d -m 0755 /etc/sudoers.d
ensure_sudoers "$APP_SSH_USER"

APP_HOME="$(getent passwd "$APP_SSH_USER" | cut -d: -f6)"
APP_SSH_GROUP="$(install_deploy_ssh_dir "$APP_SSH_USER" "$APP_HOME")"
AUTH_KEYS="$APP_HOME/.ssh/authorized_keys"
touch "$AUTH_KEYS"

# install_authorized_keys <authorized_keys> [home root]
#
# Give the deploy user a way in: the explicit SSH_PUBLIC_KEY when there is one,
# otherwise whatever key Lightsail installed for the default cloud user.
install_authorized_keys() {
  local auth_keys="$1" home_root="${2:-/home}" candidate src
  if [ -n "$SSH_PUBLIC_KEY" ]; then
    grep -qxF "$SSH_PUBLIC_KEY" "$auth_keys" ||
      printf '%s\n' "$SSH_PUBLIC_KEY" >> "$auth_keys"
    return 0
  fi
  for candidate in ubuntu admin ec2-user; do
    src="$home_root/$candidate/.ssh/authorized_keys"
    [ -s "$src" ] || continue
    # APP_SSH_USER may *be* the cloud user, in which case there is nothing to
    # copy — and appending a file to itself is not a harmless no-op: GNU cat
    # refuses with "input file is output file" and exits 1, which under
    # `set -e` would abort provisioning here, before Docker and PostgreSQL are
    # installed. -ef rather than string equality, so a symlinked or
    # bind-mounted home resolves to the same answer.
    if [ "$src" -ef "$auth_keys" ]; then
      log "APP_SSH_USER is the cloud user '$candidate' — its keys are already in place"
    else
      log "no SSH_PUBLIC_KEY given — copying keys from $candidate"
      cat "$src" >> "$auth_keys"
    fi
    return 0
  done
}

# revoke_prior_ssh_key <authorized_keys> [state file]
#
# The counterpart of revoke_prior_deploy_user and reassign_prior_db_role, for
# the same reason and on the same account: a re-run with a changed
# SSH_PUBLIC_KEY appends the new key and leaves the old one authorized. This
# account is in `docker` and has passwordless sudo, so a key the operator
# believes they retired still reaches root — the rotation reports success and
# withdraws nothing.
#
# Only the key *this script* installed is withdrawn, recorded in a state file
# rather than guessed at, so keys an operator added by hand and the cloud
# user's original key are never touched.
#
# The record is per account, because authorized_keys is. A single global marker
# loses track as soon as APP_SSH_USER moves and comes back: rotate
# collavre/key-A to deploybot/key-B, and collavre keeps key-A (correctly — its
# file is not the one being rewritten) while the marker advances to key-B. Come
# back to collavre with key-C and the withdrawal hunts for key-B, which was
# never in this file, so key-A survives — on an account the same re-run has just
# put back in `docker` and sudoers. A key retired two rotations ago is root
# again, and nothing says so.

# install_staged_authorized_keys <staged file> <authorized_keys>
#
# Put a fully-written staging file at the live path, atomically. Both callers
# below stage first and then have to install what they staged, and both got
# this wrong in the same way, so it lives in one place.
#
# `cat "$tmp" > "$auth_keys"` is not the same thing, which is the part that
# looks like a detail and is not. The shell performs the `>` redirect — an
# O_TRUNC — in the forked child, and only then execs the writer, so the live
# file is empty across an entire process spawn rather than across a single
# write(2). Killing that child at a uniformly random point, on a realistic
# four-key file:
#
#   cat "$tmp" > "$auth_keys"   damaged 7/400, all of them 0 bytes
#   mv "$tmp" "$auth_keys"      damaged 0/400
#
# Every damaged run had lost the successor key, which is the whole file. An OOM
# kill during provisioning is the realistic way to land in that window on a
# 512MB instance — the same memory pressure SWAP_SIZE_MB exists for, and step 2
# has not necessarily helped yet.
#
# The ownership is set on the staging file rather than after the rename,
# because the obvious form of this fix has a lockout of its own: mktemp creates
# 0600 root-owned, and sshd refuses an authorized_keys it cannot read as the
# user. Measured against a real sshd with StrictModes on:
#
#   owner=collavre mode=600 -> OK       owner=root mode=600 -> Authentication
#   owner=root     mode=644 -> OK       refused: bad ownership or modes
#
# So a crash between a bare `mv` and the caller's `chown` would leave the host
# refusing the very key the run just installed. Setting both first means the
# file is correct at every instant, and the caller's chown/chmod becomes a
# no-op rather than a load-bearing step.
install_staged_authorized_keys() {
  local tmp="$1" auth_keys="$2"
  [ -z "${APP_SSH_USER:-}" ] || chown "$APP_SSH_USER:${APP_SSH_GROUP:-$APP_SSH_USER}" "$tmp" 2>/dev/null || true
  chmod 0600 "$tmp"
  mv -f "$tmp" "$auth_keys"
}

revoke_prior_ssh_key() {
  local auth_keys="$1" state="${2:-$STATE_DIR/ssh_public_key.$APP_SSH_USER}" prior tmp
  # An empty SSH_PUBLIC_KEY means "keep using the cloud user's keys", not
  # "retire the managed one" — withdrawing here would strand an operator who
  # simply dropped the variable from a re-run.
  [ -n "$SSH_PUBLIC_KEY" ] || return 0
  # Never revoke before the successor is actually in place: an interrupted run
  # must leave two usable keys, never zero.
  grep -qxF "$SSH_PUBLIC_KEY" "$auth_keys" || return 0

  if [ -f "$state" ]; then
    prior="$(cat "$state")"
    if [ -n "$prior" ] && [ "$prior" != "$SSH_PUBLIC_KEY" ] &&
       grep -qxF "$prior" "$auth_keys"; then
      # Staged beside the target rather than in $TMPDIR: same filesystem, so
      # the rewrite below cannot fail for space the staging just proved is
      # there, and a small or full /tmp is not on its own able to break the
      # file the operator logs in with.
      tmp="$(mktemp "$auth_keys.revoke.XXXXXX")"
      # Exact whole-line match: a key is withdrawn only if it is byte-for-byte
      # the one recorded, so an operator key that merely shares a comment or a
      # prefix survives.
      grep -vxF "$prior" "$auth_keys" > "$tmp" || true
      # Check what the staged file *is*, not merely that it exists. `grep`
      # writing a short file is the dangerous case and it is the likely one:
      # the successor was appended, so it is the last line, and a write that
      # runs out of space stops before reaching it. A size test passes on
      # that file, `cat` installs it, and the account is locked out of a host
      # whose log says the rotation succeeded. The `|| true` above — needed so
      # `set -e` does not fire on grep's "no lines selected" — is what hides
      # the error, so the successor's presence has to be re-established here.
      if grep -qxF "$SSH_PUBLIC_KEY" "$tmp"; then
        install_staged_authorized_keys "$tmp" "$auth_keys"
        log "withdrew the SSH key this script installed on a previous run"
      else
        rm -f "$tmp"
        log "WARNING: could not withdraw the previous SSH key — is the disk full?" \
            "It is still authorized; remove it by hand once the host is healthy"
        # Deliberately leave the marker pointing at the key still in the file,
        # so the next run retries the withdrawal instead of forgetting it.
        return 0
      fi
    fi
  fi
  printf '%s\n' "$SSH_PUBLIC_KEY" > "$state"
}

# dedupe_authorized_keys <authorized_keys> [key that must survive]
#
# `sort -u -o F F` rewrites F in place, and F is the only way into this host.
#
# A full filesystem is not the hazard, which is worth stating because it is the
# obvious guess: GNU sort reads all of its input before it opens the output, and
# opening it frees that file's own blocks, so the result — never larger than the
# input — fits by construction. Measured on a 0 KiB filesystem, the file came
# through intact. What is dangerous is anything that stops sort *after* it has
# truncated the output: the write is not atomic, and the file is left holding a
# prefix of itself. On a 512MB instance an OOM kill is the realistic one — the
# same memory pressure SWAP_SIZE_MB exists for, and step 8 has not run yet:
#
#   sort -u -o F F, killed mid-write:  60001 lines -> 28659, current key gone
#
# Note which key goes missing. The file is being sorted, so the survivors are a
# lexical prefix and the casualty is whatever sorts last — not necessarily the
# key just installed, and not something the caller can predict.
#
# So sort into a sibling and rename. Same directory, so the swap is one
# rename(2) and the live path only ever holds a complete file; a sort that dies
# damages the staging file and nothing else. The successor is confirmed present
# before the swap, the same rule as revoke_prior_ssh_key above.
dedupe_authorized_keys() {
  local auth_keys="$1" must_keep="${2:-}" tmp
  tmp="$(mktemp "$auth_keys.sort.XXXXXX")"
  if sort -u -o "$tmp" "$auth_keys" 2>/dev/null &&
     { [ ! -s "$auth_keys" ] || [ -s "$tmp" ]; } &&
     { [ -z "$must_keep" ] || grep -qxF "$must_keep" "$tmp"; }; then
    install_staged_authorized_keys "$tmp" "$auth_keys"
    return 0
  fi
  rm -f "$tmp"
  # Not fatal, and deliberately so: duplicate lines in authorized_keys stop
  # nobody logging in, so the file as it stands is correct if untidy. Failing
  # the run here would abandon provisioning over cosmetics — but the operator
  # should know the host could not complete a small write.
  log "WARNING: could not rewrite $auth_keys to drop duplicate keys, so it is" \
      "unchanged — logins are unaffected. Something stopped a small write on" \
      "this host; check its memory and disk before relying on the instance."
}

# The single marker an earlier revision wrote has already been re-filed against
# the account authorized_keys says it belongs to, up beside the sudo grant —
# see adopt_legacy_ssh_key_marker. It has to happen there rather than here: the
# case it refuses is one where this run would otherwise re-arm a key it cannot
# identify, and by this point the sudo half of that is already done.
install_authorized_keys "$AUTH_KEYS"
revoke_prior_ssh_key "$AUTH_KEYS"
dedupe_authorized_keys "$AUTH_KEYS" "$SSH_PUBLIC_KEY"
chown "$APP_SSH_USER:$APP_SSH_GROUP" "$AUTH_KEYS"
chmod 0600 "$AUTH_KEYS"
[ -s "$AUTH_KEYS" ] || log "WARNING: $AUTH_KEYS is empty — kamal will not be able to connect"

# --------------------------------------------------------------------------
log "4/9 Docker CE"
# --------------------------------------------------------------------------
if ! command -v docker >/dev/null 2>&1; then
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
    -o /etc/apt/keyrings/docker.asc
  chmod a+r /etc/apt/keyrings/docker.asc
  # shellcheck disable=SC1091
  . /etc/os-release
  cat > /etc/apt/sources.list.d/docker.list <<EOF
deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $VERSION_CODENAME stable
EOF
  apt_get update -y
  apt_install docker-ce docker-ce-cli containerd.io \
    docker-buildx-plugin docker-compose-plugin
fi

# Cap container logs — an unrotated Rails log fills a Lightsail SSD fast.
install -d -m 0755 /etc/docker
DAEMON_JSON_CHANGED=0
ensure_docker_log_caps
systemctl enable docker
if [ "$DAEMON_JSON_CHANGED" -eq 1 ]; then
  # The package starts the daemon during install, so it is already running with
  # the stock config by the time we get here — `enable --now` would leave it
  # that way and the log caps would not apply until something restarted Docker.
  # Only on a run that changed the file, so a re-run never bounces live
  # containers. On an existing instance that restart does bounce them, once:
  # they come back under their restart policy, and an uncapped log filling the
  # disk takes the whole host down rather than one container.
  systemctl restart docker
else
  systemctl start docker
fi
usermod -aG docker "$APP_SSH_USER"
# Only once the replacement can reach Docker, so an interrupted run never
# leaves the host with no account that can deploy.
revoke_prior_deploy_user "$APP_SSH_USER"

# --------------------------------------------------------------------------
log "5/9 PostgreSQL $PG_MAJOR"
# --------------------------------------------------------------------------
# Before the apt install, not after: once a second cluster exists it has already
# taken a port, and the only way back is pg_upgradecluster or a delete.
ensure_cluster_on_default_port

if ! [ -d "/etc/postgresql/$PG_MAJOR/main" ]; then
  install -d -m 0755 /usr/share/postgresql-common/pgdg
  curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc \
    -o /usr/share/postgresql-common/pgdg/apt.postgresql.org.asc
  # shellcheck disable=SC1091
  . /etc/os-release
  cat > /etc/apt/sources.list.d/pgdg.list <<EOF
deb [signed-by=/usr/share/postgresql-common/pgdg/apt.postgresql.org.asc] https://apt.postgresql.org/pub/repos/apt $VERSION_CODENAME-pgdg main
EOF
  apt_get update -y
  apt_install "postgresql-$PG_MAJOR" "postgresql-client-$PG_MAJOR"
fi

# postgresql_conf_includes_confd <postgresql.conf>
#
# Whether an *active* include_dir already pulls in conf.d. The distinction is
# the whole point of the function. Debian and Ubuntu ship this directive live
# in the stock postgresql.conf, so on a fresh install the managed block is
# correctly skipped — but an operator who commented it out on an existing host
# leaves the same text in the file, and a plain substring match reads their
# `#include_dir = 'conf.d'` as "already configured".
#
# Measured on ubuntu:24.04 with the stock line commented out: the run writes
# conf.d/10-collavre.conf, restarts cleanly and reports success, and PostgreSQL
# never reads the file. listen_addresses stays at `localhost`, so nothing binds
# the docker bridge while DATABASE_URL hands the containers 172.17.0.1:5432 —
# the failure surfaces as the app being unable to reach its own database,
# several steps after the step that caused it.
#
# Comments are stripped before the test rather than anchored around, because an
# active directive can carry a trailing one and a disabled one can be indented
# or spaced (`  #  include_dir = ...`). The path is matched as a whole final
# component so `include_dir = 'myconf.d'` is not read as conf.d.
postgresql_conf_includes_confd() {
  sed 's/#.*//' "$1" |
    grep -qE "^[[:space:]]*include_dir[[:space:]]*=[[:space:]]*'?([^']*/)?conf\.d'?[[:space:]]*$"
}

PG_CONF_DIR="/etc/postgresql/$PG_MAJOR/main"
[ -d "$PG_CONF_DIR/conf.d" ] || install -d -m 0755 "$PG_CONF_DIR/conf.d"
postgresql_conf_includes_confd "$PG_CONF_DIR/postgresql.conf" || \
  ensure_block "$PG_CONF_DIR/postgresql.conf" include "include_dir = 'conf.d'"

TOTAL_MB=$(awk '/MemTotal/ {printf "%d", $2/1024}' /proc/meminfo)
SHARED_BUFFERS_MB=$(( TOTAL_MB / 4 ))
EFFECTIVE_CACHE_MB=$(( TOTAL_MB / 2 ))
MAINTENANCE_MB=$(( TOTAL_MB / 16 ))
[ "$MAINTENANCE_MB" -lt 64 ] && MAINTENANCE_MB=64

cat > "$PG_CONF_DIR/conf.d/10-collavre.conf" <<CONF
# Managed by script/lightsail_launch.sh — edit here, not in postgresql.conf.
listen_addresses = 'localhost,$DB_BIND_ADDRESS'
password_encryption = scram-sha-256

max_connections = 100
shared_buffers = ${SHARED_BUFFERS_MB}MB
effective_cache_size = ${EFFECTIVE_CACHE_MB}MB
maintenance_work_mem = ${MAINTENANCE_MB}MB
work_mem = 8MB

# SSD-backed block storage.
random_page_cost = 1.1
effective_io_concurrency = 200
wal_compression = on

log_min_duration_statement = 1000
log_line_prefix = '%m [%p] %q%u@%d '
timezone = '$TIMEZONE'
CONF

# Containers authenticate with a password over the docker bridge.
ensure_block "$PG_CONF_DIR/pg_hba.conf" docker \
  "host    all    all    $DOCKER_SUBNETS    scram-sha-256"

systemctl enable postgresql
systemctl restart postgresql

# --------------------------------------------------------------------------
log "6/9 database '$DB_NAME' and role '$DB_USER'"
# --------------------------------------------------------------------------
# Before anything moves — and that includes $STATE_DIR, not just the database.
# A rotation away from a superuser predecessor cannot be completed, so it must
# not be started, and the refusal says "Nothing has been changed": it has to be
# true. Recording the new DB_PASSWORD first made it false in a way that outlived
# the run. The refused run left the new password in the state file while the
# live role still had the old one, so the recovery this very message recommends
# — re-run with the previous DB_USER and no DB_PASSWORD — read the unapplied
# value back and applied it, silently rotating the password of a role whose
# credential nobody asked to change. The already-deployed DATABASE_URL then
# names a password the server no longer accepts, which surfaces as
# authentication failures the next time the app reconnects rather than at the
# moment the mistake is made.
#
# The name guard runs first, and the order is load-bearing rather than
# alphabetical. refuse_superuser_db_rotation asks how many objects the previous
# role owns *in $DB_NAME*, so when a re-run changes both, it asks that question
# of a database that does not exist: psql fails, the count comes back empty, and
# the "unanswerable reads as unsafe" rule turns that into a refusal blaming
# object ownership. Measured on postgres:17, re-running a DB_USER=postgres host
# with a new role and a mistyped name:
#
#   DIE: ... An unknown number of object(s) in 'collavre_prod' are still owned
#        by 'postgres' ... Move the objects by hand
#
# Nothing is changed either way, so this is not a data-safety difference — but
# the by-hand transfer it sends the operator to cannot be performed on a
# database that is not there, which is the same dead end as a guard whose own
# recovery is unreachable. Asking about the name first names the real problem.
refuse_db_name_change "$DB_NAME"

# Beside it, and before the password handling for the same reason: a refusal
# here must not have written anything to $STATE_DIR either.
refuse_superuser_db_rotation "$DB_USER"

if [ -z "$DB_PASSWORD" ]; then
  if [ -f "$STATE_DIR/db_password" ]; then
    # Re-run: keep the password already handed out in DATABASE_URL.
    DB_PASSWORD="$(cat "$STATE_DIR/db_password")"
  else
    # URL-safe alphabet only: this password goes into DATABASE_URL verbatim.
    DB_PASSWORD="$(openssl rand -base64 48 | tr -dc 'A-Za-z0-9' | head -c 32)"
    log "generated a random database password"
  fi
fi
# The umask is what makes this 0600, not the chmod. A bare redirection creates
# the file 0644 under the default umask and only narrows it a command later,
# and $STATE_DIR is 0755 — so the production password would be world-readable
# for that window, or permanently if the run were interrupted between the two.
# The chmod stays to converge a file an earlier revision left 0644.
( umask 077; printf '%s' "$DB_PASSWORD" > "$STATE_DIR/db_password" )
chmod 0600 "$STATE_DIR/db_password"

# Mirrors db/setup_postgres_databases.sql: create-if-missing, never drop.
# Collavre keeps primary/cache/queue/cable in ONE database — the Solid Queue,
# Cache and Cable tables are created by a primary db/migrate migration. Do not
# add separate _cache/_queue/_cable databases.
SQL_FILE="$(mktemp /tmp/collavre-db.XXXXXX.sql)"
trap 'rm -f "$SQL_FILE"' EXIT
ESCAPED_PASSWORD="${DB_PASSWORD//\'/\'\'}"
cat > "$SQL_FILE" <<SQL
\set ON_ERROR_STOP on
SELECT format('CREATE ROLE %I LOGIN', '$DB_USER')
WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname = '$DB_USER')
\gexec
ALTER ROLE "$DB_USER" PASSWORD '$ESCAPED_PASSWORD';
SELECT format('CREATE DATABASE %I OWNER %I', '$DB_NAME', '$DB_USER')
WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = '$DB_NAME')
\gexec
ALTER DATABASE "$DB_NAME" OWNER TO "$DB_USER";
SQL
chown postgres "$SQL_FILE"
chmod 0600 "$SQL_FILE"
runuser -u postgres -- psql -v ON_ERROR_STOP=1 -q -d postgres -f "$SQL_FILE"
rm -f "$SQL_FILE"
trap - EXIT

# After the role and database exist, before the summary hands out a
# DATABASE_URL naming the new role.
reassign_prior_db_role "$DB_USER"
printf '%s\n' "$DB_USER" > "$STATE_DIR/db_user"
# Recorded only once the database it names actually exists, so an interrupted
# run cannot leave a marker for a database that was never created.
printf '%s\n' "$DB_NAME" > "$STATE_DIR/db_name"

# --------------------------------------------------------------------------
log "7/9 firewall"
# --------------------------------------------------------------------------
# No `ufw reset`: this script is re-runnable, and a reset months later would
# take a VPN, monitoring or IP-allowlist rule with it. Only the rules below are
# ours to converge.
ufw default deny incoming
ufw default allow outgoing

ensure_ssh_rule
ufw allow 80/tcp
ufw allow 443/tcp
# PostgreSQL is only listening on localhost and the docker bridge, so this rule
# is defence in depth rather than the only thing keeping it private.
ensure_ufw_rule postgres \
  "allow from $DOCKER_SUBNETS to $DB_BIND_ADDRESS port $DB_PORT proto tcp"
ufw --force enable
ufw status verbose

# --------------------------------------------------------------------------
log "8/9 nightly backups"
# --------------------------------------------------------------------------
# Owned by postgres: pg_dump writes the file itself, and 0700 keeps the dumps
# readable only by postgres and root.
install -d -m 0700 -o postgres -g postgres /var/backups/collavre

# Ubuntu ships no `aws`, so an S3 destination is useless without installing it
# first. Official v2 installer rather than the apt package: noble's awscli is a
# release behind and this has to work on 24.04 for years.
if [ -n "$BACKUP_S3_URI" ] && ! command -v aws >/dev/null 2>&1; then
  case "$(uname -m)" in
    aarch64 | arm64) AWS_CLI_ARCH=aarch64 ;;
    *) AWS_CLI_ARCH=x86_64 ;;
  esac
  AWS_CLI_TMP="$(mktemp -d)"
  if curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-${AWS_CLI_ARCH}.zip" \
       -o "$AWS_CLI_TMP/awscliv2.zip" &&
     unzip -q "$AWS_CLI_TMP/awscliv2.zip" -d "$AWS_CLI_TMP" &&
     "$AWS_CLI_TMP/aws/install" --update >/dev/null; then
    hash -r
    log "AWS CLI installed for S3 backup upload ($(aws --version 2>&1))"
  else
    log "WARNING: could not install the AWS CLI — nightly backups will stay local" \
        "and collavre-pg-backup.service will fail until you install it by hand"
  fi
  rm -rf "$AWS_CLI_TMP"
fi

cat > /usr/local/bin/collavre-pg-backup <<BACKUP
#!/usr/bin/env bash
# Managed by script/lightsail_launch.sh
set -euo pipefail
DEST=/var/backups/collavre
DB_NAME="$DB_NAME"
RETENTION_DAYS=$BACKUP_RETENTION_DAYS
S3_URI="$BACKUP_S3_URI"

install -d -m 0700 -o postgres -g postgres "\$DEST"
STAMP="\$(date +%Y%m%d-%H%M%S)"
FILE="\$DEST/\${DB_NAME}-\${STAMP}.dump"

trap 'rm -f "\$FILE"' ERR
runuser -u postgres -- pg_dump --format=custom --compress=6 --port=$DB_PORT \\
  --dbname="\$DB_NAME" --file="\$FILE"
trap - ERR
chmod 0600 "\$FILE"

# A configured S3 destination that silently does nothing is worse than no
# off-instance backup at all, because it looks like one. Report the local dump
# either way, then exit non-zero so the systemd unit goes red.
S3_STATUS=0
if [ -n "\$S3_URI" ]; then
  if ! command -v aws >/dev/null 2>&1; then
    echo "ERROR: S3_URI is set but the aws CLI is not installed —" \\
         "\$FILE exists only on this instance" >&2
    S3_STATUS=1
  elif ! aws s3 cp "\$FILE" "\${S3_URI%/}/\$(basename "\$FILE")"; then
    echo "ERROR: upload to \${S3_URI%/} failed —" \\
         "\$FILE exists only on this instance" >&2
    S3_STATUS=1
  fi
fi

find "\$DEST" -maxdepth 1 -name '*.dump' -mtime "+\$RETENTION_DAYS" -delete
echo "backup complete: \$FILE (\$(du -h "\$FILE" | cut -f1))"
exit "\$S3_STATUS"
BACKUP
chmod 0755 /usr/local/bin/collavre-pg-backup

cat > /etc/systemd/system/collavre-pg-backup.service <<'UNIT'
[Unit]
Description=Collavre PostgreSQL dump
After=postgresql.service

[Service]
Type=oneshot
ExecStart=/usr/local/bin/collavre-pg-backup
UNIT

cat > /etc/systemd/system/collavre-pg-backup.timer <<UNIT
[Unit]
Description=Nightly Collavre PostgreSQL dump

[Timer]
OnCalendar=*-*-* $BACKUP_AT:00
Persistent=true

[Install]
WantedBy=timers.target
UNIT

systemctl daemon-reload
systemctl enable --now collavre-pg-backup.timer

# --------------------------------------------------------------------------
log "9/9 summary"
# --------------------------------------------------------------------------
PUBLIC_IP="$(curl -fsS --max-time 5 https://checkip.amazonaws.com 2>/dev/null || echo '<public-ip>')"
PRIVATE_IP="$(hostname -I | awk '{print $1}')"
# Rails percent-decodes userinfo when it resolves DATABASE_URL, so encoding
# here round-trips back to the literal password the role was created with.
URL_USER="$(urlencode "$DB_USER")"
URL_PASSWORD="$(urlencode "$DB_PASSWORD")"
URL_DB_NAME="$(urlencode "$DB_NAME")"
DATABASE_URL="postgresql://$URL_USER:$URL_PASSWORD@$DB_BIND_ADDRESS:$DB_PORT/$URL_DB_NAME"
# Angle brackets, not a $(...) that a reader might paste into .env.production
# and watch dotenv store verbatim.
REDACTED_URL="postgresql://$URL_USER:<see $SUMMARY>@$DB_BIND_ADDRESS:$DB_PORT/$URL_DB_NAME"
# Only worth saying when the two actually differ, which they never do for the
# generated password.
PASSWORD_NOTE=''
if [ "$URL_PASSWORD" != "$DB_PASSWORD" ]; then
  PASSWORD_NOTE=', percent-encoded in the URL below'
fi

# Rendered twice: once with the real DATABASE_URL into the 0600 summary file,
# once redacted for stdout — which is tee'd to the launch log and captured by
# cloud-init. Templating instead of sed'ing the secret out keeps a password
# containing regex or delimiter characters from slipping through unreplaced.
render_summary() { # $1 = DATABASE_URL to display
  cat <<TXT
Collavre Lightsail host — provisioned $(date -Is)

  public IP        $PUBLIC_IP
  private IP       $PRIVATE_IP
  deploy user      $APP_SSH_USER (docker, passwordless sudo)
  PostgreSQL       $PG_MAJOR, listening on localhost + $DB_BIND_ADDRESS only
  database         $DB_NAME owned by $DB_USER
  db password      $STATE_DIR/db_password (root only)$PASSWORD_NOTE
  launch config    $STATE_DIR/launch.env — a re-run applies every setting, so
                   repeat these on the command line or it is refused
  backups          /var/backups/collavre, nightly at $BACKUP_AT, ${BACKUP_RETENTION_DAYS}d retention
  log              $LOG_FILE

Put these in .env.production at the root of your Collavre checkout, then run
\`./kamal.sh setup\` from that same directory — the wrapper is what loads
.env.production; plain \`bin/kamal\` does not read it and would deploy with no
host and the wrong SSH user:

  COLLAVRE_SERVER=$PUBLIC_IP
  KAMAL_SSH_USER=$APP_SSH_USER
  KAMAL_SSH_KEY_PATH=~/.ssh/<the key matching the instance>
  DATABASE_URL=$1
  PORT=80

Open ports 80 and 443 in the Lightsail console firewall (Networking tab).
Never open 5432 there.
TXT
}

# What this run was configured with, so the next one can tell an omitted
# override from a deliberate default (refuse_defaulted_config_change). Written
# only here, after every step has succeeded: a run that died halfway must not
# leave a record claiming the host is configured the way it was asked to be.
# No DB_PASSWORD — it has its own 0600 file, and this one is world-readable
# because the answers in it ("which deploy user?", "which database?") are what
# the runbook sends operators here to read.
{ for _s in $LAUNCH_SETTINGS; do printf '%s=%s\n' "$_s" "${!_s}"; done; } \
  > "$STATE_DIR/launch.env"
chmod 0644 "$STATE_DIR/launch.env"
unset _s

touch "$SUMMARY"
chmod 0600 "$SUMMARY"
render_summary "$DATABASE_URL" > "$SUMMARY"

touch "$MARKER"
render_summary "$REDACTED_URL"
log "done — full log at $LOG_FILE (root only; the DATABASE_URL above is redacted, the real one is in $SUMMARY)"
