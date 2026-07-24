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
#   2. a deploy user (default: collavre) in the docker group, for `kamal`
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

# Append a managed block to a config file exactly once, keyed by a marker.
ensure_block() {
  local file="$1" marker="$2" content="$3"
  if grep -qF "# BEGIN collavre:$marker" "$file" 2>/dev/null; then
    return 0
  fi
  {
    printf '\n# BEGIN collavre:%s (managed by script/lightsail_launch.sh)\n' "$marker"
    printf '%s\n' "$content"
    printf '# END collavre:%s\n' "$marker"
  } >> "$file"
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

APP_HOME="$(getent passwd "$APP_SSH_USER" | cut -d: -f6)"
install -d -m 0700 -o "$APP_SSH_USER" -g "$APP_SSH_USER" "$APP_HOME/.ssh"
AUTH_KEYS="$APP_HOME/.ssh/authorized_keys"
touch "$AUTH_KEYS"

if [ -n "$SSH_PUBLIC_KEY" ]; then
  grep -qxF "$SSH_PUBLIC_KEY" "$AUTH_KEYS" || printf '%s\n' "$SSH_PUBLIC_KEY" >> "$AUTH_KEYS"
else
  # Reuse whatever key Lightsail installed for the default cloud user.
  for candidate in ubuntu admin ec2-user; do
    src="/home/$candidate/.ssh/authorized_keys"
    if [ -s "$src" ]; then
      log "no SSH_PUBLIC_KEY given — copying keys from $candidate"
      cat "$src" >> "$AUTH_KEYS"
      break
    fi
  done
fi
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

# --------------------------------------------------------------------------
log "5/9 PostgreSQL $PG_MAJOR"
# --------------------------------------------------------------------------
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
printf '%s' "$DB_PASSWORD" > "$STATE_DIR/db_password"
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

# --------------------------------------------------------------------------
log "7/9 firewall"
# --------------------------------------------------------------------------
ufw --force reset >/dev/null
ufw default deny incoming
ufw default allow outgoing
ufw allow OpenSSH
ufw allow 80/tcp
ufw allow 443/tcp
# PostgreSQL is only listening on localhost and the docker bridge, so this rule
# is defence in depth rather than the only thing keeping it private.
ufw allow from "$DOCKER_SUBNETS" to "$DB_BIND_ADDRESS" port 5432 proto tcp
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
runuser -u postgres -- pg_dump --format=custom --compress=6 \\
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
DATABASE_URL="postgresql://$DB_USER:$DB_PASSWORD@$DB_BIND_ADDRESS:5432/$DB_NAME"
# Angle brackets, not a $(...) that a reader might paste into .env.production
# and watch dotenv store verbatim.
REDACTED_URL="postgresql://$DB_USER:<see $SUMMARY>@$DB_BIND_ADDRESS:5432/$DB_NAME"

# Rendered twice: once with the real DATABASE_URL into the 0600 summary file,
# once redacted for stdout — which is tee'd to the launch log and captured by
# cloud-init. Templating instead of sed'ing the secret out keeps a password
# containing regex or delimiter characters from slipping through unreplaced.
render_summary() { # $1 = DATABASE_URL to display
  cat <<TXT
Collavre Lightsail host — provisioned $(date -Is)

  public IP        $PUBLIC_IP
  private IP       $PRIVATE_IP
  deploy user      $APP_SSH_USER (docker, sudo)
  PostgreSQL       $PG_MAJOR, listening on localhost + $DB_BIND_ADDRESS only
  database         $DB_NAME owned by $DB_USER
  db password      $STATE_DIR/db_password (root only)
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
