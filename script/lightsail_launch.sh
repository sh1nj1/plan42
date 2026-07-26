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

if [ -f "$MARKER" ] && [ "${FORCE:-0}" != "1" ]; then
  log "already provisioned ($MARKER). Re-run with FORCE=1 to converge again."
  exit 0
fi

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
reassign_prior_db_role() {
  local current="$1" prior_file="${2:-$STATE_DIR/db_user}" prior
  [ -f "$prior_file" ] || return 0
  prior="$(cat "$prior_file")"
  [ -n "$prior" ] && [ "$prior" != "$current" ] || return 0
  [ "$(psql_as_postgres postgres \
        "SELECT count(*) FROM pg_roles WHERE rolname = '$prior'")" = 1 ] || return 0

  # Never touch a superuser. DB_USER=postgres on a first run is a legal thing
  # to have done, and NOLOGIN on the cluster superuser locks every operator out
  # of administering it — peer auth needs LOGIN too, so there is no way back in.
  if [ "$(psql_as_postgres postgres \
            "SELECT rolsuper FROM pg_roles WHERE rolname = '$prior'")" = t ]; then
    log "WARNING: previous DB_USER '$prior' is a superuser — leaving it alone;" \
        "move ownership and retire it by hand if that is what you meant"
    return 0
  fi

  psql_as_postgres "$DB_NAME" "REASSIGN OWNED BY \"$prior\" TO \"$current\""
  log "moved ownership of everything in '$DB_NAME' from '$prior' to '$current'"
  psql_as_postgres postgres "ALTER ROLE \"$prior\" NOLOGIN"
  log "revoked LOGIN from the replaced database role '$prior'"
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
  local name="$1" rule="$2" state="${3:-$STATE_DIR/ufw_$1}" prior
  if [ -f "$state" ]; then
    prior="$(cat "$state")"
    if [ -n "$prior" ] && [ "$prior" != "$rule" ]; then
      # Unquoted on purpose: a rule is a word list, not one argument.
      # shellcheck disable=SC2086
      ufw delete $prior >/dev/null 2>&1 &&
        log "withdrew the previous $name rule: $prior"
    fi
  fi
  # shellcheck disable=SC2086
  ufw $rule >/dev/null
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
# Deliberately positive: it answers "is 22 open?", never "is 22 closed?". An
# empty or unparseable `ufw status` therefore means we add the rule, because
# guessing wrong in that direction only re-opens SSH, while guessing wrong in
# the other enables a deny-by-default firewall on a host with no way in.
ssh_already_allowed() {
  ufw status 2>/dev/null | grep -qE '^(22|OpenSSH)([/[:space:]]).*(ALLOW|LIMIT)'
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
if [ "$SWAP_SIZE_MB" -gt 0 ] && ! swapon --show=NAME --noheadings | grep -q '/swapfile'; then
  if [ ! -f /swapfile ]; then
    fallocate -l "${SWAP_SIZE_MB}M" /swapfile || \
      dd if=/dev/zero of=/swapfile bs=1M count="$SWAP_SIZE_MB" status=none
    chmod 600 /swapfile
    mkswap /swapfile
  fi
  swapon /swapfile
  ensure_block /etc/fstab swap "/swapfile none swap sw 0 0"
fi
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

if ! id -u "$APP_SSH_USER" >/dev/null 2>&1; then
  adduser --disabled-password --gecos "Collavre deploy" "$APP_SSH_USER"
fi
usermod -aG sudo "$APP_SSH_USER"
install -d -m 0755 /etc/sudoers.d
ensure_sudoers "$APP_SSH_USER"

APP_HOME="$(getent passwd "$APP_SSH_USER" | cut -d: -f6)"
install -d -m 0700 -o "$APP_SSH_USER" -g "$APP_SSH_USER" "$APP_HOME/.ssh"
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
revoke_prior_ssh_key() {
  local auth_keys="$1" state="${2:-$STATE_DIR/ssh_public_key}" prior tmp
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
        cat "$tmp" > "$auth_keys"   # rewrite in place, keeping mode and owner
        rm -f "$tmp"
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

install_authorized_keys "$AUTH_KEYS"
revoke_prior_ssh_key "$AUTH_KEYS"
sort -u -o "$AUTH_KEYS" "$AUTH_KEYS"
chown "$APP_SSH_USER:$APP_SSH_USER" "$AUTH_KEYS"
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
DAEMON_JSON_WRITTEN=0
if [ ! -f /etc/docker/daemon.json ]; then
  cat > /etc/docker/daemon.json <<'JSON'
{
  "log-driver": "json-file",
  "log-opts": { "max-size": "10m", "max-file": "3" }
}
JSON
  DAEMON_JSON_WRITTEN=1
fi
systemctl enable docker
if [ "$DAEMON_JSON_WRITTEN" -eq 1 ]; then
  # The package starts the daemon during install, so it is already running with
  # the stock config by the time we get here — `enable --now` would leave it
  # that way and the log caps would not apply until something restarted Docker.
  # Only on the run that wrote the file, so a re-run never bounces live
  # containers.
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

PG_CONF_DIR="/etc/postgresql/$PG_MAJOR/main"
[ -d "$PG_CONF_DIR/conf.d" ] || install -d -m 0755 "$PG_CONF_DIR/conf.d"
grep -q "include_dir = 'conf.d'" "$PG_CONF_DIR/postgresql.conf" || \
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

touch "$SUMMARY"
chmod 0600 "$SUMMARY"
render_summary "$DATABASE_URL" > "$SUMMARY"

touch "$MARKER"
render_summary "$REDACTED_URL"
log "done — full log at $LOG_FILE (root only; the DATABASE_URL above is redacted, the real one is in $SUMMARY)"
