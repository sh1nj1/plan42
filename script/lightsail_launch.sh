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
# these settings converge by *rotating*: a deploy-user cutover is staged for
# whatever APP_SSH_USER now says, and table ownership and LOGIN
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
BACKUP_CALENDAR="*-*-* $BACKUP_AT:00"

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

# refuse_defaulted_config_change [state dir] [supplied settings]
#
# A re-run applies every setting, not just the ones it was given: an override
# the operator used the first time and did not repeat is applied as its
# default. For most of these that is harmless convergence, but three of them
# are not convergence at all —
#
#   APP_SSH_USER   stages a new account and a one-time SSH cutover challenge;
#                  finalization moves docker + sudo away from the account in
#                  $STATE_DIR/deploy_user only after a real successor session
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

  # Which settings launch.env actually answered, so the fallback below can cover
  # the ones it did not. Presence of the file is not the question — see there.
  local answered=' '
  if [ -f "$env_file" ]; then
    record="The host's own record of what it was given is $env_file."
    # Driven by the current setting list rather than by the file's lines, so a
    # value this revision no longer has, or a line an editor mangled, cannot be
    # turned into an indirect expansion of an arbitrary name.
    for name in $LAUNCH_SETTINGS; do
      case " $supplied " in *" $name "*) continue ;; esac
      grep -q "^$name=" "$env_file" || continue
      answered="$answered$name "
      prior="$(sed -n "s/^$name=//p" "$env_file" | head -1)"
      now="${!name}"
      [ "$prior" = "$now" ] && continue
      note_drift "$name" "$prior" "$now"
    done
  fi

  # Per setting rather than "launch.env is absent", because the file existing is
  # not the same as the file answering, and the branch that conflated them was
  # reachable without an editor or an upgrade. launch.env is written with one
  # redirection at the very end of a run, so a full disk or an interruption
  # between the truncate and the last line leaves it present and short — and
  # every missing line is skipped in silence by the `grep -q ... || continue`
  # above. Measured on the shipped function, with an empty launch.env beside a
  # $STATE_DIR that names the provisioned accounts:
  #
  #   no launch.env      REFUSES   (answered from deploy_user / db_user)
  #   launch.env empty   PROCEEDS  <- the guard checked nothing at all
  #
  # and what proceeds is the bare `FORCE=1` re-run this exists to refuse: it
  # rotates the deploy account and the database role away from the ones the
  # deployed .env.production and DATABASE_URL still name. The two settings that
  # rotate a live credential have their own state files, which are written at
  # the step that performs the rotation rather than at the end of the run, so
  # they answer for a host whose launch.env is absent *or* short.
  for pair in deploy_user:APP_SSH_USER db_user:DB_USER; do
    file="${pair%%:*}"; name="${pair##*:}"
    case "$answered" in *" $name "*) continue ;; esac
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
  if [ ! -f "$env_file" ] && [ -n "$record" ]; then
    record="This host predates $env_file, so what it was
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

# refuse_unusable_db_identifier <setting name> <value>
#
# DB_NAME and DB_USER reach PostgreSQL through format('%I'), which quotes
# whatever it is given — so the cluster accepts names this script then cannot
# work with, and accepts them silently. Measured on a live cluster:
#
#   CREATE via format('%I'), DB_NAME='tenant/prod'   -> created
#   pg_dump --dbname='tenant/prod'                   -> rc=0, connects
#   --file=/var/backups/collavre/tenant/prod-<stamp>.dump
#                                                    -> rc=1, no such directory
#
# The database is real, the app runs against it, and every nightly dump fails
# from the moment the host is provisioned — the one failure on this host that
# is only discovered by needing a backup. The same two values are also spliced
# into the SQL below as *string literals* ('$DB_NAME'), where a name containing
# a quote ends the run at step 6 with a syntax error naming a file in /tmp.
#
# Refused here rather than sanitised into a safe filename, because a sanitised
# name is a second spelling: the runbook restores from
# "/var/backups/collavre/$app_db-<stamp>.dump" using the name in
# $STATE_DIR/db_name, and a transform in between would have to exist in two
# places and stay equal. One spelling everywhere is the property worth keeping.
#
# Hyphens are allowed: `collavre-prod` needs identifier quoting, which the
# runbook and the SQL below both do, and it is a perfectly good filename. A
# leading hyphen is not, because that is an option to every command that later
# handles the dump.
#
# LC_ALL=C so the ranges below are byte ranges. Under a UTF-8 collation
# [A-Za-z] matches accented letters, which is exactly the class of name this
# is here to keep out of a path.
refuse_unusable_db_identifier() {
  local LC_ALL=C setting="$1" value="$2"
  case "$value" in
    ''|-*|*[!A-Za-z0-9_-]*) ;;
    *) return 0 ;;
  esac
  die "REFUSING: $setting='$value' is a name PostgreSQL would accept and this" \
      "script cannot use. Use letters, digits, '_' and '-', not starting with" \
      "'-'. DB_NAME is spelled outside SQL as well as in it — the nightly dump" \
      "is written to /var/backups/collavre/\$DB_NAME-<stamp>.dump, so a '/'" \
      "puts it in a directory that does not exist and every backup fails — and" \
      "both settings go into the CREATE statements as string literals, where a" \
      "quote of your own ends the run before the database is made." \
      "Nothing has been changed. If this host was already provisioned under" \
      "that name its backups have never run, and setting a different DB_NAME" \
      "is refused by refuse_db_name_change: rename the database and update" \
      "$STATE_DIR/db_name first — 'Changing DB_NAME on a re-run' in" \
      "docs/deploy_to_lightsail.md — then re-run with the new name."
}

# ipv4_dotted_quad <value>
#
# Four decimal octets, 0-255, no leading zeros — `010` is 8 to inet_pton and 10
# to a reader, and this value is spelled into three files that do not have to
# agree about which. Written with case and arithmetic rather than a regex
# because [[ =~ ]] does not mean the same thing under the bash macOS ships as
# under the bash Lightsail runs, and this suite is run under both.
ipv4_dotted_quad() {
  local LC_ALL=C rest="$1" octet count=0
  while [ "$count" -lt 4 ]; do
    if [ "$count" -lt 3 ]; then
      case "$rest" in
        *.*) octet="${rest%%.*}"; rest="${rest#*.}" ;;
        *) return 1 ;;
      esac
    else
      octet="$rest"; rest=''
    fi
    case "$octet" in
      0|[1-9]|[1-9][0-9]|[1-9][0-9][0-9]) ;;
      *) return 1 ;;
    esac
    [ "$octet" -le 255 ] || return 1
    count=$((count + 1))
  done
  [ -z "$rest" ]
}

# refuse_unusable_bind_address <setting name> <value>
# refuse_unusable_subnet <setting name> <value>
#
# DB_BIND_ADDRESS and DOCKER_SUBNETS are spliced into generated PostgreSQL
# configuration — listen_addresses and a pg_hba.conf line — and into a ufw rule
# and DATABASE_URL. Neither was checked, and the generated files are installed
# by rename and then `systemctl restart postgresql`. Measured on a real cluster
# with `include_dir = 'conf.d'` and this script's own generated file:
#
#   DB_BIND_ADDRESS          postgres -C   the cluster after a restart
#   172.17.0.1               rc=0          UP, listening on the bridge
#   172.17.0.999             rc=0          UP, WARNING, listening on localhost
#   bogus.invalid            rc=0          UP, WARNING, listening on localhost
#   1.2.3.4                  rc=0          UP, WARNING, listening on localhost
#   not a host               rc=0          DOWN, FATAL: invalid list syntax
#
#   DOCKER_SUBNETS           the cluster after a restart
#   172.16.0.0/12            UP, the rule matches
#   not-a-subnet             UP, read as a host name, the rule never matches
#   172.16.0.0/99            DOWN, FATAL: invalid CIDR mask in address
#   "172.16.0.0/12 all trust"  DOWN, FATAL: invalid authentication method "all"
#
# Two bands, and the loud one is not the dangerous one. A value that breaks the
# *syntax* stops the cluster on a FORCE=1 convergence — the live database goes
# down and does not come back, which is the failure the reviewer describes and
# it is at least visible. A value that is merely wrong starts perfectly: the
# cluster is healthy, `systemctl status` is green, and it is listening on
# localhost alone, or carrying a pg_hba rule that matches nothing. The app's
# containers cannot reach the database and nothing on the host says why — the
# same quiet ending as a truncated config, arrived at from a live value.
#
# Checked here rather than by validating the staged file, which is what the
# finding asks for and does not close it. `postgres -C listen_addresses` exits
# 0 on every row above, including the one that will not start: the list is
# parsed at startup, not by the GUC machinery. And the value lands inside single
# quotes, so one of its own ends them — measured, DB_BIND_ADDRESS set to
# `172.17.0.1'<newline>fsync = off<newline>#` gives a staged file that validates
# and starts, with `postgres -C fsync` reporting `off`. A validator can only
# ever say the file is a configuration; it cannot say it is this one.
#
# Restoring the previous file when the restart fails is the other half the
# finding offers, and it treats the quiet band as a success: there is no failed
# restart to trigger it.
refuse_unusable_bind_address() {
  local setting="$1" value="$2"
  if ipv4_dotted_quad "$value"; then
    case "$value" in
      0.0.0.0)
	die "REFUSING: $setting='$value' is the unspecified address. PostgreSQL" \
	    "may listen successfully on the host, but DATABASE_URL is used" \
	    "inside the application container, where 0.0.0.0 names the" \
	    "container rather than the host database. Nothing has been changed." \
	    "Set $setting to the gateway address of the bridge your containers" \
	    "are on — 'ip -4 addr show docker0'."
	;;
      127.*)
	die "REFUSING: $setting='$value' is a loopback address. PostgreSQL would" \
	    "listen successfully on the host, but DATABASE_URL is used inside" \
	    "the application container, where 127.0.0.0/8 names the container" \
	    "itself rather than the host database. Nothing has been changed." \
	    "Set $setting to the gateway address of the bridge your containers" \
	    "are on — 'ip -4 addr show docker0'."
	;;
    esac
    return 0
  fi
  die "REFUSING: $setting='$value' is not an IPv4 address. It is written into" \
      "PostgreSQL's listen_addresses, into a ufw rule and into DATABASE_URL," \
      "and PostgreSQL does not refuse it: an address it cannot bind is a" \
      "warning, so the cluster comes back up listening on localhost only and" \
      "no container can reach it, on a host this run would have reported as" \
      "converged. A value carrying a space or a quote is worse — it ends the" \
      "quoting of the generated file. Nothing has been changed. The default is" \
      "172.17.0.1, the docker0 bridge gateway; set $setting to the gateway" \
      "address of the bridge your containers are on — 'ip -4 addr show docker0'."
}

refuse_unusable_subnet() {
  local setting="$1" value="$2" addr bits
  case "$value" in
    */*/*) ;;
    */*)
      addr="${value%/*}"; bits="${value#*/}"
      case "$bits" in
        0|[1-9]|[12][0-9]|3[0-2]) ipv4_dotted_quad "$addr" && return 0 ;;
      esac
      ;;
  esac
  die "REFUSING: $setting='$value' is not an IPv4 network in CIDR form. It is" \
      "written into a pg_hba.conf line and into a ufw rule. A malformed mask" \
      "stops PostgreSQL from starting at all; a value that merely is not a" \
      "network is read as a host name, and the cluster starts with a rule that" \
      "matches nothing — every container is then refused with 'no pg_hba.conf" \
      "entry' on a run that reported success. One network, not a list: the" \
      "pg_hba address field and 'ufw allow from' each take exactly one." \
      "Nothing has been changed. The default is 172.16.0.0/12, which covers" \
      "every Docker bridge network."
}

# refuse_unusable_retention <setting name> <value>
#
# BACKUP_RETENTION_DAYS is %q-quoted into the generated backup program and used
# only there, as `find -mtime "+$RETENTION_DAYS"`. `bash -n` on the staged
# program parses it fine and the timer is enabled, so nothing on this side of
# provisioning says anything: the value is first read by GNU find at the hour
# BACKUP_AT names — 03:30 by default — on a host the summary already reported
# as converged, hours earlier. Measured by running the
# generated program with each value, GNU findutils 4.8.0:
#
#   BACKUP_RETENTION_DAYS   rc   dumps left       the unit
#   7                       0    the new dump     green, "backup complete: (4.0K)"
#   seven                   1    new + the old    RED, invalid argument `+seven'
#   ''                      1    new + the old    RED, invalid argument `+'
#   -1                      0    NONE             green, "backup complete: ()"
#
# Two bands again, and the loud one is not the dangerous one. `seven` fails
# every night with the unit red and dumps accumulating until the disk fills —
# which is the finding, and it is at least visible in `systemctl list-units
# --failed`. `-1` is the one worth this guard: find takes `+-1`, deletes every
# dump *including the one just taken*, and the program still exits 0 and prints
# "backup complete" for a file that is no longer there. A green nightly timer
# and an empty backup directory is the worst reading of the four.
#
# Refused here, before the unit is installed, rather than checked in the
# generated program: a program that validates its own retention has already
# taken the dump by the time it can complain, and the only place "nothing has
# been changed" is true is up here with the other value guards.
#
# Whole non-negative integers only. `7.5` happens to work on GNU find and is
# refused anyway — one spelling, and a retention this script cannot restate as
# a whole number of days is not one an operator should have to reason about.
refuse_unusable_retention() {
  local setting="$1" value="$2"
  case "$value" in
    ''|*[!0-9]*) ;;
    *) return 0 ;;
  esac
  die "REFUSING: $setting='$value' is not a whole number of days. It is used" \
      "as 'find -mtime +$value' in the nightly backup, which provisioning" \
      "installs and enables without ever running — so this would first be" \
      "read at $BACKUP_AT, on a host reported as converged. A value find" \
      "rejects leaves the timer failing every night while dumps accumulate;" \
      "a negative one is worse, because find accepts it and deletes every" \
      "dump including the one just taken, while the run still exits 0 and" \
      "reports 'backup complete'. Nothing has been changed. The default is 7."
}

# refuse_unusable_backup_calendar <setting name> <configured value> <calendar>
#
# Validate the exact expression installed below, before the staged timer can
# replace a working live unit. systemctl only parses OnCalendar after the
# replacement, which is too late to preserve the prior schedule on failure.
refuse_unusable_backup_calendar() {
  local setting="$1" value="$2" calendar="$3"
  if command -v systemd-analyze >/dev/null 2>&1 &&
     systemd-analyze calendar "$calendar" >/dev/null 2>&1
  then
    return 0
  fi
  die "REFUSING: $setting='$value' does not produce a valid systemd calendar" \
      "expression ('$calendar'). The existing PostgreSQL backup timer is left" \
      "unchanged. Use a 24-hour HH:MM time; the default is 03:30."
}

# refuse_unparsable_ssh_key
#
# SSH_PUBLIC_KEY is appended to authorized_keys verbatim, and its own presence
# in that file is then taken as proof the successor works: revoke_prior_ssh_key
# withdraws the previously installed key once `grep -qxF` finds this one there.
# Whole-line presence is not parsability, and the [ -s ] check at the end of the
# run is satisfied by any text at all, so a truncated paste ends with the deploy
# account holding one line sshd cannot read and nothing else. Measured through
# the shipped functions with a real key missing 24 characters of its body:
#
#   before   lines=1 usable=1
#   after    lines=1 usable=0    "withdrew the SSH key this script installed"
#
# and against a scratch sshd, which is the only authority on "usable":
#
#   truncated line   -> Permission denied (publickey)
#   same key intact  -> LOGGED-IN-OK
#
# The marker is advanced to the truncated key as well, so the host's own record
# of the key that worked is overwritten and there is nothing for a later run to
# retry toward. Hence a refusal here, before anything is appended or withdrawn,
# rather than a check at the install: at this point nothing has been changed and
# the operator can still fix the paste.
#
# ssh-keygen is the check because it is sshd's own parser. It accepts the forms
# an operator legitimately supplies — no comment, a command=/from= restriction,
# leading whitespace — and refuses truncation, which no shape check short of
# parsing the blob can catch. A regex strict enough for the second would refuse
# the first.
#
# A newline is refused for its own reason: `grep -qxF` treats each line of its
# pattern as a separate pattern, so a two-line value counts as "in place" as
# soon as either half of it is, and the withdrawal proceeds on half a key.
#
# Where ssh-keygen is absent this cannot be answered, and it warns rather than
# refusing: openssh-server depends on openssh-client, so a host without
# ssh-keygen is a host without sshd, and stopping there would cost provisioning
# for a check with no login to protect.
#
# The value is not echoed. An operator who pastes a private key by mistake is
# exactly the case this refuses, and the provisioning log is not private.
refuse_unparsable_ssh_key() {
  local tmp head rc=0
  [ -n "$SSH_PUBLIC_KEY" ] || return 0
  case "$SSH_PUBLIC_KEY" in
    *$'\n'*) rc=1 ;;
    *)
      if ! command -v ssh-keygen >/dev/null 2>&1; then
        log "WARNING: ssh-keygen is not installed, so SSH_PUBLIC_KEY could not be" \
            "checked. If sshd cannot read it, this run will still withdraw the key" \
            "it replaces — confirm you can log in as $APP_SSH_USER before you rely" \
            "on this host."
        return 0
      fi
      tmp="$(mktemp)"
      printf '%s\n' "$SSH_PUBLIC_KEY" > "$tmp"
      ssh-keygen -l -f "$tmp" >/dev/null 2>&1 || rc=1
      rm -f "$tmp"
      ;;
  esac
  if [ "$rc" != 0 ]; then
    head="${SSH_PUBLIC_KEY%%[ $'\n']*}"
    die "REFUSING: SSH_PUBLIC_KEY is not a key sshd can read — ssh-keygen" \
        "cannot parse it, and a line cut short by a copy-paste is the usual" \
        "reason. What was given is ${#SSH_PUBLIC_KEY} characters beginning" \
        "'${head:0:20}'. Nothing has been changed. Left to run, this would" \
        "append it to $APP_SSH_USER's authorized_keys, then withdraw the key" \
        "it replaces on the strength of finding this one in the file, and the" \
        "account would be left with no key sshd accepts — a rotation that" \
        "reports success and locks you out. Paste the whole single line from" \
        "your .pub file, and check it first if you like:" \
        "ssh-keygen -l -f your_key.pub."
  fi
}

# refuse_forced_command_ssh_key
#
# refuse_unparsable_ssh_key asks sshd's own parser whether the line is a key,
# and deliberately accepts the option prefixes an operator legitimately holds.
# `command="..."` is one sshd reads perfectly and one this account cannot do its
# job with: sshd runs that command *instead of* the one the client asked for, so
# every remote command Kamal sends is discarded. Measured against a scratch
# sshd, one authorized_keys line at a time, the client asking for
# `echo KAMAL-REMOTE-COMMAND-RAN`:
#
#   authorized_keys line             ssh-keygen -l   rc    what actually ran
#   <key>                            parses           0    the command
#   from="127.0.0.1" <key>           parses           0    the command
#   no-pty,no-agent-forwarding <key> parses           0    the command
#   restrict <key>                   parses           0    the command
#   restrict,pty <key>               parses           0    the command
#   command="/usr/bin/false" <key>   parses           1    nothing
#   command="/usr/bin/true"  <key>   parses           0    nothing
#
# The last row is the one worth refusing for. It is not a deploy that fails —
# it is a deploy whose every step reports success while nothing is executed, on
# a host whose provisioning also reported success. And the five rows above it
# are why this is a separate question rather than "refuse a line with options":
# they are the forms the guard above exists to keep working, and each of them
# runs the client's command.
#
# The options are the first whitespace-delimited field before the key type and
# blob. Whitespace inside a quoted option value does not end that field, and an
# escaped quote does not end the value. Parse that boundary rather than looking
# for base64 text: an option value is allowed to contain the same `AAAA` with
# which an SSH key blob begins.
#
# Refused rather than checked after the install, for the reason the guard above
# gives: revoke_prior_ssh_key withdraws the predecessor as soon as `grep -qxF`
# finds this line in the file, and finding it there is not evidence that a
# command can be run through it. There is no client here to prove that with, so
# the only place the question can be answered is before anything is appended.
refuse_forced_command_ssh_key() {
  local has_forced_command
  [ -n "$SSH_PUBLIC_KEY" ] || return 0
  # Folded, because sshd matches the option *name* without regard to case and a
  # case-sensitive test here is a bypass rather than a narrower guard. Measured
  # against a real sshd, one authorized_keys line at a time, the client asking
  # for `echo CLIENT-COMMAND-RAN`:
  #
  #   authorized_keys line              ssh rc   what actually ran
  #   command="/usr/bin/true" <key>     0        nothing
  #   COMMAND="/usr/bin/true" <key>     0        nothing
  #   CoMmAnD="/usr/bin/true" <key>     0        nothing
  #   no-pty,COMMAND="/usr/bin/true"    0        nothing
  #   RESTRICT <key>                    0        the client's command
  #
  # The last row is the control and it is why only the name is folded and the
  # question is still "is this a forced command": an uppercase option is not on
  # its own a reason to refuse a key sshd is happy to run the client's command
  # through.
  #
  # Parse the comma-separated option names rather than searching the whole
  # field: `environment="NOTE=command=value"` carries those bytes as data and
  # does not replace the client command. awk's tolower() keeps this compatible
  # with bash 3.2 on macOS while matching sshd's case-insensitive option names.
  has_forced_command="$(
    printf '%s\n' "$SSH_PUBLIC_KEY" |
      awk '
	{
	  start = 1
	  while (start <= length($0) &&
		 substr($0, start, 1) ~ /[[:space:]]/) {
	    start++
	  }
	  quoted = 0
	  escaped = 0
	  option_start = start
	  seen_equals = 0
	  for (i = start; i <= length($0); i++) {
	    char = substr($0, i, 1)
	    if (escaped) {
	      escaped = 0
	    } else if (quoted && char == "\\") {
	      escaped = 1
	    } else if (char == "\"") {
	      quoted = !quoted
	    } else if (!quoted && char ~ /[[:space:]]/) {
	      exit
	    } else if (!quoted && char == ",") {
	      option_start = i + 1
	      seen_equals = 0
	    } else if (!quoted && char == "=" && !seen_equals) {
	      if (tolower(substr($0, option_start, i - option_start)) == "command") {
		print "yes"
		exit
	      }
	      seen_equals = 1
	    }
	  }
	}
      '
  )"
  [ "$has_forced_command" = yes ] || return 0
  die "REFUSING: SSH_PUBLIC_KEY carries a forced command. sshd reads the key" \
      "fine, and then runs that command in place of whatever the client asks" \
      "for — so 'kamal deploy' would connect, run the forced command, and" \
      "either fail on every step or, if the command exits 0, report every step" \
      "as done without running any of it. Nothing has been changed. Left to" \
      "run, this would be appended to $APP_SSH_USER's authorized_keys and the" \
      "key it replaces withdrawn on the strength of finding this one in the" \
      "file. Supply the plain line from your .pub file; restrictions that do" \
      "not replace the command — from=, no-pty, restrict — are accepted."
}

# refuse_root_deploy_user <user>
#
# The deploy account cannot be UID 0, because step 3 writes `PermitRootLogin no`
# into /etc/ssh/sshd_config.d/01-collavre.conf and then, further down that same
# step, arms $APP_SSH_USER and hands it to Kamal as KAMAL_SSH_USER. Nothing in
# between rejects the account sshd has just been told to turn away, so the run
# reports success and every deploy fails to authenticate.
#
# Refused here rather than at the deploy-user block so that "nothing has been
# changed" is literally true: by the time that block runs, a rotation has a
# predecessor to take sudo and docker back from, and it would be stripped in
# favour of an account that cannot log in — leaving the host with no working
# way in at all. The remedy for that is on the host, which is the thing you no
# longer have.
#
# Tested by UID rather than by the name 'root', since an account aliased to 0
# is locked out by exactly the same drop-in. An account that does not exist yet
# is fine: `adduser` below creates an ordinary one.
refuse_root_deploy_user() {
  local user="$1" uid
  uid="$(id -u "$user" 2>/dev/null)" || return 0
  [ "$uid" -eq 0 ] || return 0
  die "APP_SSH_USER='$user' is UID 0, and this script hardens sshd with" \
      "PermitRootLogin no before it arms the deploy account — so '$user' could" \
      "never log in, while the summary would still print KAMAL_SSH_USER=$user" \
      "and every 'kamal deploy' would fail to authenticate. Nothing has been" \
      "changed. Set APP_SSH_USER to an ordinary account; leave it unset for the" \
      "default 'collavre', which this script creates."
}

# refuse_nologin_deploy_user <user>
#
# The guard above states the invariant it does not test. Its own message is
# "'$user' could never log in, while the summary would still print
# KAMAL_SSH_USER=$user and every 'kamal deploy' would fail to authenticate" —
# which is true word for word of a service account whose shell is
# /usr/sbin/nologin, and which it accepts. Measured against 6125e4ee:
#
#   account   shell               id -u        guard
#   root      /bin/sh             0            REFUSES
#   nobody    /usr/sbin/nologin   65534        PROCEEDS
#   daemon    /usr/sbin/nologin   1            PROCEEDS
#
# Kamal runs its commands over `ssh <user>@host <command>`, and a nologin shell
# refuses command execution the same way it refuses a session — so the account
# is armed with docker and sudo, published as KAMAL_SSH_USER, and every deploy
# fails. On a rotation it is worse than a failed run: the predecessor's docker
# and sudo are taken back in favour of an account that cannot execute anything,
# and the remedy for that is on the host you no longer have a way into.
#
# Placed with refuse_root_deploy_user and for the same reason: refusing at the
# deploy-user block would already be past the point where a rotation has a
# predecessor to strip.
#
# Only accounts that already exist are tested. One that does not is created by
# `adduser` below with an ordinary shell, and treating "cannot resolve" as
# "might be nologin" would refuse every fresh host — the same reasoning the UID
# check above records.
refuse_nologin_deploy_user() {
  local user="$1" shell run_as probe
  id -u "$user" >/dev/null 2>&1 || return 0
  shell="$(getent passwd "$user" | cut -d: -f7)"
  # An account `id -u` resolves but `getent passwd` will not describe is not a
  # pass. The question this guard asks is "can this account run a command", and
  # an unanswerable question has to read as the unsafe answer — the same rule
  # role_owns_app_objects states and the psql probes had to be taught.
  [ -n "$shell" ] ||
    die "APP_SSH_USER='$user' exists but this host will not say what login" \
        "shell it has, so this run cannot tell an ordinary account from a" \
        "service account that can never run a 'kamal deploy'. Nothing has been" \
        "changed. Check 'getent passwd $user', or set APP_SSH_USER to an" \
        "account this host describes."
  # Tested by running it rather than by matching names: /usr/sbin/nologin,
  # /sbin/nologin, /bin/false and /usr/bin/false are four spellings across two
  # distributions of one behaviour, and a fifth would read as though the
  # question had been answered. A shell that exits non-zero on `-c true` cannot
  # run a deploy command, whatever it is called.
  [ -x "$shell" ] ||
    die "APP_SSH_USER='$user' has login shell '$shell', which is not executable" \
        "on this host, so sshd can start no command for it and every" \
        "'kamal deploy' would fail after this script had already given the" \
        "account docker and passwordless sudo. Nothing has been changed. Fix" \
        "the account with 'usermod -s /bin/bash $user', or set APP_SSH_USER to" \
        "an ordinary account."
  "$shell" -c true >/dev/null 2>&1 ||
    die "APP_SSH_USER='$user' has login shell '$shell', which refuses to run a" \
        "command — this is what /usr/sbin/nologin and /bin/false do, and it is" \
        "how service accounts like 'nobody' and 'www-data' are configured." \
        "Kamal deploys by running commands over ssh, so this account would be" \
        "armed with docker and passwordless sudo, published as" \
        "KAMAL_SSH_USER=$user, and unable to execute anything. Nothing has been" \
        "changed. Fix the account with 'usermod -s /bin/bash $user', or set" \
        "APP_SSH_USER to an ordinary account; leave it unset for the default" \
        "'collavre', which this script creates."
  # And again as the account, because everything above ran as root and root can
  # execute files the deploy user cannot. A custom login shell installed
  # mode-0700 root:root is the case: measured on a real host, `[ -x ]` answers
  # yes, `"$shell" -c true` passes, and what sshd actually does after switching
  # to the deploy UID answers "Permission denied". So the root-run probe reports
  # a shell this account can never start.
  #
  # `runuser` first, `su` only if it is absent: both were measured to give the
  # same answer on every row, but `runuser` is the conservative one — it is the
  # tool for root switching without authentication, so a host with PAM rules
  # that would question an interactive `su` cannot turn this probe into a
  # refusal. If neither exists the root probe above is all this host allows, and
  # that is not a reason to refuse: a missing util-linux would fail every run.
  #
  # The controls this had to keep, all measured: an ordinary account whose
  # password is locked — which is what `adduser --disabled-password` leaves, so
  # it is every key-only deploy account including the one this script creates —
  # passes, as does one with no home directory or a home it cannot read. An
  # account that is *expired* refuses here, and that is the right answer: sshd
  # would refuse it too.
  run_as=''
  for probe in runuser su; do
    command -v "$probe" >/dev/null 2>&1 && { run_as="$probe"; break; }
  done
  case "$run_as" in
    runuser) runuser -u "$user" -- "$shell" -c true >/dev/null 2>&1 ;;
    su)      su -s "$shell" -c true "$user" >/dev/null 2>&1 ;;
    *)       true ;;
  esac ||
    die "APP_SSH_USER='$user' has login shell '$shell', which this script can" \
        "run as root but '$user' cannot — a shell the account is not permitted" \
        "to execute, or an expired account. sshd starts that shell after" \
        "switching to the deploy UID, so every 'kamal deploy' would fail with" \
        "the account already holding docker and passwordless sudo and the" \
        "summary printing KAMAL_SSH_USER=$user. Nothing has been changed." \
        "Check with 'runuser -u $user -- $shell -c true' and" \
        "'ls -l $shell', or set APP_SSH_USER to an ordinary account."
}

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

# resolve_symlink_chain <path> — echo the real path a symlink chain ends at.
#
# Lifted out of ensure_block so that every install-by-rename in this script
# resolves the same way. rename(2) does not follow symlinks and `cat > file`
# does, so converting a copy to a rename without this replaces the *link* with a
# regular file and leaves the real path — the one every other reader resolves to
# — holding what it held before. That is a worse failure than the truncation the
# rename is there to fix, because it is silent and permanent rather than loud
# and one-run, and /etc/docker/daemon.json is exactly the kind of file config
# management symlinks.
#
# Not `readlink -f`: a GNU extension that only reached macOS recently, and this
# suite runs on both. Relative targets resolve against the link's own directory
# rather than $PWD.
resolve_symlink_chain() {
  local file="$1" hops=0 target
  while [ -L "$file" ]; do
    target="$(readlink "$file")" ||
      die "$file: is a symlink I cannot read. Repair or replace it by hand."
    case "$target" in
      /*) file="$target" ;;
      *)  file="$(dirname "$file")/$target" ;;
    esac
    hops=$((hops + 1))
    [ "$hops" -lt 16 ] ||
      die "$file: symlink chain is too deep to follow. Repair it by hand."
  done
  printf '%s\n' "$file"
}

# stage_beside <target> — echo the path of a staging file in the target's own
# directory, already carrying the target's owner and mode.
#
# The caller writes its content into that path and renames it over the target,
# so the live file is never the thing being written to. `> file` truncates when
# the redirection opens, which makes the window the whole write rather than an
# instant, and every caller of this that generates a file had that window.
#
# Same directory, not $TMPDIR: rename(2) needs one filesystem, and /etc and /tmp
# are commonly separate mounts — across them `mv` degrades to copy-then-unlink,
# which is the window again. Staging there also proves the space is available
# before the live file is at risk.
#
# `cp -p` rather than chmod/chown --reference: --reference is a GNU extension
# and this suite's cases run on macOS as well as the Ubuntu the script
# provisions. Copying the target's identity rather than naming a mode is the
# point — the callers span root:root 0644, postgres:postgres 0640 and
# root:root 0755, and spelling any of them here would be a second spelling of
# what the target already says, wrong the first time a caller points it at a
# new file.
#
# The second argument is the mode to use when the target does not exist yet,
# and it is not optional in spirit: mktemp creates 0600, which a bare
# redirection under root's umask never would. Installing a first-run
# 10-collavre.conf at 0600 root:root would leave PostgreSQL — which reads
# /etc/postgresql/*/main/conf.d as the postgres user — unable to read the file
# this script just wrote, so the fix for a truncated config would stop the
# cluster outright. 0644 is what `cat >` produced and what the callers want.
stage_beside() {
  local target tmp mode="${2:-0644}"
  target="$(resolve_symlink_chain "$1")" || return 1
  tmp="$(mktemp "$target.collavre.XXXXXX")" || return 1
  # A staging file that cannot be given the target's identity is not installed:
  # proceeding at mktemp's 0600 would trade a converged file for a daemon that
  # cannot read its own configuration.
  if [ -e "$target" ]; then
    if ! cp -p "$target" "$tmp" 2>/dev/null; then
      rm -f "$tmp"
      return 2
    fi
  elif ! chmod "$mode" "$tmp"; then
    rm -f "$tmp"
    return 2
  fi
  printf '%s\n' "$tmp"
}

# restore_postgresql_bind_config <live file> <backup> <had prior: 0|1>
#
# Put back the managed listen-address file after a replacement cannot be
# reached. The backup is a sibling made by stage_beside; each rollback stages
# from it and renames that copy over the live path, atomically restoring the
# prior owner and mode while retaining the backup until restart succeeds. On a
# first run there was no file to restore; removing the new one returns
# PostgreSQL to the stock localhost-only setting. Restarting is part of the
# rollback: merely restoring the bytes would leave the postmaster running
# whichever config the failed restart loaded.
restore_postgresql_bind_config() {
  local live_file="$1" backup="$2" had_prior="$3" restore_tmp
  if [ "$had_prior" -eq 1 ]; then
    [ -f "$backup" ] || return 1
    restore_tmp="$(stage_beside "$live_file")" || return 1
    if ! cp -p "$backup" "$restore_tmp" 2>/dev/null ||
       ! mv -f "$restore_tmp" "$live_file"; then
      rm -f "$restore_tmp"
      return 1
    fi
  else
    rm -f "$live_file" || return 1
  fi
  systemctl restart postgresql || return 2
  [ -z "$backup" ] || rm -f "$backup"
}

# install_managed_config <label> <target> <line>...
#
# Write a whole config file this script owns: every line is put in a staging
# file beside the target, read back, and only then renamed over it, so the live
# file is never the one being written to. Blank and comment lines are written
# but not read back — they are not what the file is for.
#
# Reading the staged file back is the part that does not follow from "stage and
# rename", and it is the part the quiet failures need. `printf` can report
# success for a short write, and both of the states a truncated drop-in leaves —
# zero bytes, or cut after the first directive — are files every validator
# accepts. `sshd -t` answers rc=0 for an empty file; so does `jq empty`, which
# is the same fact the daemon.json rewrite rests on. A validator can say the
# staged file is a configuration. Only a read-back can say it is *this* one.
install_managed_config() {
  local label="$1" target="$2" tmp rc line
  shift 2
  # Resolved here, and the rename below goes to the resolved path — the same
  # thing ensure_block does at its top and the 10-collavre.conf write spells
  # out as PG_CONF_REAL. stage_beside resolves internally, so renaming onto the
  # unresolved argument would put the staging file beside the *backing* file
  # and the finished one beside the link. Two consequences, and the second is
  # the one this function exists to prevent:
  #
  #   target                     after the install
  #   /etc/plain.conf (control)  rewritten in place, no leftovers
  #   /etc/link.conf -> /real/backing.conf
  #                              /etc/link.conf is now a REGULAR FILE
  #                              /real/backing.conf still holds the old content
  #
  # The operator's symlink is replaced, so the file they were editing stops
  # taking effect. And because the staging file was made beside the resolved
  # target, a link that crosses a filesystem turns the `mv` into a
  # copy-then-unlink — the non-atomic write this whole function is here to
  # avoid, reintroduced on exactly the hosts where the staging is doing
  # something.
  #
  # `|| exit 1` rather than `|| return 1`: resolve_symlink_chain die()s inside
  # a command substitution, so its exit kills only that subshell. Carrying on
  # would rename onto an empty path — the same fault ensure_block's case 4b
  # asserts the status for rather than the message.
  target="$(resolve_symlink_chain "$target")" || exit 1
  tmp="$(stage_beside "$target" 0644)"; rc=$?
  [ "$rc" -eq 0 ] || {
    die "could not stage $label at $target (stage_beside exited $rc). The" \
        "live file is left exactly as it was and nothing has been granted."
  }
  if ! printf '%s\n' "$@" > "$tmp"; then
    rm -f "$tmp"
    die "could not write the staged $label — is the instance out of disk?" \
        "$target is left as it was."
  fi
  for line in "$@"; do
    case "$line" in ''|'#'*) continue ;; esac
    grep -qxF "$line" "$tmp" && continue
    rm -f "$tmp"
    die "the staged $label came out without '$line' — refusing to install it" \
        "over $target, which is left as it was. A file that parses is not one" \
        "that does its job: an empty drop-in passes every validator there is" \
        "and silently gives back whatever it was supposed to set."
  done
  mv -f "$tmp" "$target" || {
    rm -f "$tmp"
    die "could not install the staged $label over $target, which is left as" \
        "it was."
  }
}

# install_downloaded_file <label> <url> <target>
#
# Download into a sibling of the resolved target and rename only after curl has
# completed successfully. A package source may already refer to the target on a
# FORCE re-run, so truncating it in place can make the next apt update fail
# before this step gets another chance to repair it.
install_downloaded_file() {
  local label="$1" url="$2" target="$3" target_real tmp rc=0
  target_real="$(resolve_symlink_chain "$target")" || exit 1
  tmp="$(stage_beside "$target_real" 0644)" || rc=$?
  [ "$rc" -eq 0 ] || {
    die "could not stage $label at $target_real (stage_beside exited $rc)." \
	"The live file is left exactly as it was."
  }
  if ! curl -fsSL "$url" -o "$tmp"; then
    rm -f "$tmp"
    die "could not download the staged $label. $target_real is left exactly" \
	"as it was."
  fi
  if ! chmod a+r "$tmp"; then
    rm -f "$tmp"
    die "could not make the staged $label readable. $target_real is left" \
	"exactly as it was."
  fi
  mv -f "$tmp" "$target_real" || {
    rm -f "$tmp"
    die "could not install the staged $label over $target_real, which is" \
	"left exactly as it was."
  }
}

# Keep a managed block in a config file equal to $content, keyed by a marker.
# Added on the first run; on later runs the body is replaced in place, so a
# FORCE=1 re-run with a changed DOCKER_SUBNETS or INSTANCE_HOSTNAME converges
# the host instead of leaving the previous value in force. The optional fourth
# argument `leading` moves the block ahead of every unmanaged line. PostgreSQL's
# caller uses it because pg_hba.conf is first-match-wins and even an existing
# managed block must move ahead of an operator's earlier broad reject.
ensure_block() {
  local file="$1" marker="$2" content="$3" placement="${4:-keep}"
  local begin="# BEGIN collavre:$marker" end="# END collavre:$marker"

  # Resolved before anything else, and not only for the rename below: the
  # append branch writes *through* a link and the rewrite branch replaces it,
  # so resolving here is what keeps the two branches writing to one file.
  #
  # `|| exit 1` is load-bearing. resolve_symlink_chain runs in a command
  # substitution, and the die() inside it exits only that subshell — the
  # message is printed, and this function would otherwise carry on with an
  # empty $file and return 0, reporting a converged block over a path it
  # refused to follow. Case 4b asserts the status, not just the message,
  # because the message was right while the status was wrong.
  file="$(resolve_symlink_chain "$file")" || exit 1

  local tmp rc
  if ! grep -qF "$begin" "$file" 2>/dev/null; then
    # Staged and renamed, like the rewrite below — an append is not the safer
    # half of this function. `>>` writes into the live file directly, so a kill
    # or an ENOSPC between the two printfs leaves a BEGIN with no END, and the
    # very next run stops at the malformed-block check three lines down asking
    # to be repaired by hand. That check is right to refuse: it cannot tell a
    # half-written block of this script's from an operator's edit. What it
    # costs is the file — /etc/fstab, /etc/hosts, postgresql.conf, pg_hba.conf
    # — needing an editor on a host whose provisioning has just been killed.
    #
    # There is nothing to preserve on this path and still a copy is made: the
    # rename replaces the target, so the staging file has to hold the whole
    # file, not just the block. 0644 is for a target that does not exist yet
    # — the mode `>>` produced under root's umask; every caller in this script
    # points at a file that does exist, where cp -p carries its own.
    rc=0
    tmp="$(stage_beside "$file" 0644)" || rc=$?
    case "$rc" in
      1) die "$file: could not stage the collavre:$marker block beside it. Is $(dirname "$file") writable?" ;;
      2) die "$file: could not give a staged copy the same owner and mode as the" \
             "file it replaces, so the collavre:$marker block was NOT added and" \
             "$file is untouched." ;;
    esac
    if [ "$placement" = leading ]; then
      if ! {
	printf '%s (managed by script/lightsail_launch.sh)\n' "$begin"
	printf '%s\n' "$content"
	printf '%s\n\n' "$end"
	cat "$file"
      } > "$tmp"; then
	rm -f "$tmp"
	die "$file: could not write the leading collavre:$marker block to a" \
	    "staging file beside it — is $(dirname "$file") full? $file is" \
	    "untouched."
      fi
    elif ! {
      printf '\n%s (managed by script/lightsail_launch.sh)\n' "$begin"
      printf '%s\n' "$content"
      printf '%s\n' "$end"
    } >> "$tmp"; then
      rm -f "$tmp"
      die "$file: could not write the collavre:$marker block to a staging file" \
          "beside it — is $(dirname "$file") full? $file is untouched."
    fi
    mv -f "$tmp" "$file"
    return 0
  fi

  grep -qF "$end" "$file" || \
    die "$file: '$begin' with no '$end'. Refusing to rewrite a block I cannot delimit — repair or delete it by hand."

  # Staged beside the target and carrying its identity — see stage_beside. Its
  # two failures are reported separately, because the remedies differ: 1 is
  # "nowhere to stage it" (disk, permissions), 2 is "cannot be given the
  # target's owner and mode".
  rc=0
  tmp="$(stage_beside "$file")" || rc=$?
  case "$rc" in
    1) die "$file: could not stage a rewrite beside it. Is $(dirname "$file") writable?" ;;
    2) die "$file: could not give a staged rewrite the same owner and mode as the" \
           "file it replaces, so it was NOT installed and $file is untouched." ;;
  esac
  # index() rather than an anchored match, so awk sees exactly the lines the
  # grep above found. END exits non-zero on an unterminated block (END marker
  # before BEGIN), which would otherwise swallow the rest of the file.
  if ! BLOCK_BEGIN="$begin" BLOCK_END="$end" BLOCK_BODY="$content" \
       BLOCK_PLACEMENT="$placement" awk '
      BEGIN { b = ENVIRON["BLOCK_BEGIN"]; e = ENVIRON["BLOCK_END"] }
      BEGIN {
	leading = ENVIRON["BLOCK_PLACEMENT"] == "leading"
	if (leading) {
	  print b " (managed by script/lightsail_launch.sh)"
	  print ENVIRON["BLOCK_BODY"]
	  print e
	  print ""
	}
      }
      !inside && index($0, b) {
        inside = 1
	if (!leading) {
	  print b " (managed by script/lightsail_launch.sh)"
	  print ENVIRON["BLOCK_BODY"]
	  print e
	}
        next
      }
      inside && index($0, e) {
	inside = 0
	if (leading) skip_old_separator = 1
	next
      }
      inside { next }
      leading && skip_old_separator && $0 == "" {
	skip_old_separator = 0
	next
      }
      { skip_old_separator = 0 }
      { print }
      END { if (inside) exit 1 }
    ' "$file" > "$tmp"; then
    rm -f "$tmp"
    die "$file: collavre:$marker block is malformed (END before BEGIN?). Repair it by hand."
  fi

  # Renamed, never copied through the existing inode. `cat "$tmp" > "$file"`
  # truncates the live path when the redirection opens, so a run killed during
  # the copy — an OOM kill on a 512MB instance, a power loss — leaves the file
  # holding a prefix of itself. Measured by sampling the live path during the
  # copy of a large pg_hba.conf: 0 bytes. These are the files that decide
  # whether the host comes back, and each fails a different way — an empty
  # pg_hba.conf refuses every connection, a truncated fstab loses mounts, and
  # a block left without its END marker makes the *next* run die on "repair or
  # delete it by hand" rather than converge.
  #
  # The in-place copy was there to preserve owner and mode; that is now done on
  # the staging file above, where it costs nothing and does not require the
  # live path to be destroyed first.
  mv -f "$tmp" "$file"
}

# Give $1 passwordless sudo. `usermod -aG sudo` on its own does not work here:
# `adduser --disabled-password` leaves `!` in /etc/shadow and Ubuntu's %sudo
# rule is password-authenticated, so every sudo the runbook sends over ssh
# fails with "a password is required".
#
# NOPASSWD:ALL rather than a command list. This user is already in the docker
# group, which is root-equivalent — `docker run -v /:/host` is a root shell —
# so an allowlist would withhold nothing it does not already have, while
# breaking the next maintenance command someone documents.
ensure_sudoers() {
  local user="$1" dir="${2:-/etc/sudoers.d}" tmp
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

  # Do not remove a predecessor here. A new account has not proved that it can
  # open an SSH session yet, and removing the old NOPASSWD grant before that
  # proof turns a configuration-analysis mistake into a lockout. The cutover
  # finalizer removes predecessor grants only from a session authenticated as
  # the staged account.
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

# write_state_file <path> <content>
#
# Replace a marker under $STATE_DIR in one step, because `> file` truncates when
# the redirection opens and only then writes. A write that fails in between —
# a full disk, an interrupted run — leaves the file existing and empty, and for
# the queue below that is not a state anything recovers from: the seeding in
# record_deploy_user_grant runs only when the queue file is *absent*, so an
# empty one reads as "nothing left to revoke" and the account still holding
# docker and sudo is never named again. Measured on the shipped functions, with
# `ulimit -f 0` standing in for ENOSPC:
#
#   queue [B,D] -> write fails after truncating -> queue []
#   next run                                    -> queue [E]     B unrevokable
#
# The staging file is created in the target's own directory so the rename is
# within one filesystem, where it is atomic. Anywhere else `mv` degrades to a
# copy-then-unlink and the window this exists to close is back.
#
# The default 0644 is not a widening: it is what a bare redirection already
# produced under the default umask, and the chmod is here only because mktemp
# creates 0600. db_password passes 0600 instead — it must never be 0644, even
# for the instant between the staging write and the rename, and going through
# mktemp is what guarantees that: the file is 0600 from the moment it exists,
# which the `umask 077` subshell it replaces could only achieve by getting the
# umask right.
write_state_file() {
  local target="$1" content="$2" mode="${3:-0644}" tmp
  [ ! -d "$target" ] || return 1
  tmp="$(mktemp "$target.XXXXXX")" || return 1
  if ! chmod "$mode" "$tmp" || ! printf '%s' "$content" > "$tmp"; then
    rm -f "$tmp"
    return 1
  fi
  if ! mv -f "$tmp" "$target"; then
    rm -f "$tmp"
    return 1
  fi
}

# A failed atomic replacement is recoverable only when the file it left behind
# can still answer every setting with the values this run applied. An absent,
# short or stale record is not this configuration: refuse the success marker
# rather than let the next bare FORCE=1 run silently reset an override that has
# no other state file, such as BACKUP_S3_URI.
launch_record_is_complete() {
  local env_file="$1" name count
  [ -f "$env_file" ] || return 1
  for name in $LAUNCH_SETTINGS; do
    count="$(grep -c "^$name=" "$env_file" 2>/dev/null || true)"
    [ "$count" = 1 ] || return 1
  done
}

record_launch_settings() {
  local state_dir="${1:-$STATE_DIR}" record name
  record="$(for name in $LAUNCH_SETTINGS; do
    printf '%s=%s\n' "$name" "${!name}"
  done)"
  if write_state_file "$state_dir/launch.env" "$record"$'\n'; then
    return 0
  fi
  if launch_record_is_complete "$state_dir/launch.env"; then
    if cmp -s <(printf '%s\n' "$record") "$state_dir/launch.env"; then
      log "WARNING: could not replace this run's settings in $state_dir/launch.env;" \
	  "the matching previous record is intact, so the next run still compares" \
	  "against it"
      return 0
    fi
    die "could not replace this run's settings in $state_dir/launch.env, and" \
	"the complete previous record does not match this run. Refusing to" \
	"create the success marker: a later bare FORCE=1 run would otherwise" \
	"restore settings this run changed."
  fi
  die "could not record this run's settings in $state_dir/launch.env, and no" \
      "complete previous record remains. Refusing to create the success marker:" \
      "a later bare FORCE=1 run could otherwise silently reset an override."
}

# append_state_line <set file> <line>
#
# Add one line to a queue file, or do nothing if it is already there.
#
# The three record_*_grant functions below each ended with a bare
#
#   grep -qxF "$x" "$set_file" || printf '%s\n' "$x" >> "$set_file"
#
# which is the one write in this script that write_state_file was introduced for
# and did not reach. An append cut short — ENOSPC, RLIMIT_FSIZE, an interrupted
# run — leaves the file ending in a fragment with no newline, and the *retry* is
# what does the damage: `grep -qxF` does not match the fragment, so the full
# value is appended onto the end of it and the queue gains one line that is
# neither value. Measured against 6125e4ee, with the partial write injected and
# an A -> B(torn) -> C rotation:
#
#   queue after the retry   line 1  319 bytes  exact match for B: no
#                           line 2  439 bytes  exact match for B: no   <- 120 + 319
#   after the C rotation    key B   authorized: yes   named by the queue: no
#
# The concatenated line is worse than a corrupt entry, because revoke_prior_*
# reads "not present in authorized_keys" as "already withdrawn, nothing
# outstanding" and drops it. So the queue does not merely fail to name B — it
# quietly retires the only line that ever mentioned it and ends up looking
# clean, on an account holding passwordless sudo and the docker socket.
#
# Read-modify-write rather than a smarter append: a torn write of the *whole*
# set leaves the staging file short and the live file untouched, which is the
# state a retry starts from. There is no partial-line state to be in.
append_state_line() {
  local set_file="$1" line="$2" existing=''
  grep -qxF "$line" "$set_file" 2>/dev/null && return 0
  # A trailing fragment left by an earlier revision's torn append is *not*
  # dropped here, and cannot be: nothing distinguishes half a key from a
  # different key. What this does is terminate it, so the value being recorded
  # gets its own intact line instead of being concatenated onto it. The fragment
  # then leaves on its own at the next rotation, by the revoke loop's
  # "absent from authorized_keys, nothing outstanding" path — which is the right
  # answer for it, since a fragment authorizes nobody. Measured on the A ->
  # B(torn) -> C fixture: three lines after the retry, the third an exact match
  # for B, and B withdrawn by the C rotation.
  [ -f "$set_file" ] && existing="$(grep -v '^[[:space:]]*$' "$set_file")"
  [ -z "$existing" ] || existing="$existing"$'\n'
  write_state_file "$set_file" "$existing$line"$'\n'
}

# record_deploy_user_grant <user> [set file] [single-name marker]
#
# The set of accounts this script has granted root-equivalent access to and has
# not taken it back from, one name per line.
#
# A set rather than the single predecessor an earlier revision kept, because one
# name cannot describe a host that has rotated twice. A revocation that fails
# leaves the marker naming the account it could not strip, so the *next*
# rotation retries that one and advances the marker straight past the account in
# between — which goes on holding docker and sudo with nothing on the host
# recording that it does. Measured on the extracted function:
#
#   A -> B (revoke of A fails) -> C   B left holding 'docker sudo', marker at C
#
# and no failure is needed to reach the same state. The grants are in steps 3
# and 4 and the revocation is at the end of step 4, so an interruption anywhere
# across the Docker install — an apt run, on a 512MB instance — strands B
# identically. Which is why this is called *before* the grant rather than after
# it: a name in this file that turns out to hold neither group costs a re-read
# of two group lists, and a name missing from it is root access nobody is
# looking for.
record_deploy_user_grant() {
  local user="$1" set_file="${2:-$STATE_DIR/deploy_users}"
  local prior_file="${3:-$STATE_DIR/deploy_user}"
  # Upgrade path. On a host provisioned by the earlier revision the single
  # marker names the one predecessor it knew about, and it is exactly the
  # account most likely to be unrevoked — seeding from it means the fix for
  # forgetting accounts does not begin by forgetting one.
  if [ ! -f "$set_file" ] && [ -s "$prior_file" ]; then
    local seed
    seed="$(grep -v '^[[:space:]]*$' "$prior_file")" || seed=''
    # The guard above is `! -f`, so this path runs once per host and never
    # again — whatever state the file is left in is the state it keeps. The
    # previous form's redirection created it on the way to failing and `|| true`
    # swallowed that, so an empty file answered for the predecessor from then
    # on. Returned rather than warned past, because the append below would
    # create the file too: a run that could not perform the upgrade would
    # retire it. Left absent instead, which is what a retry starts from.
    if [ -n "$seed" ]; then
      write_state_file "$set_file" "$seed"$'\n' || return 1
    fi
  fi
  append_state_line "$set_file" "$user"
}

# revoke_deploy_user_access <user> <successor>
#
# Takes docker and sudo back from one replaced account. Returns 0 when the
# account holds neither group afterwards, non-zero when it still holds one — so
# the caller decides whether to keep retrying it, rather than this deciding by
# where it writes a marker.
revoke_deploy_user_access() {
  local prior="$1" current="$2" group held sudoers_name

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
    # Deliberately kept in the set by the caller, so the next run retries the
    # revocation instead of forgetting it.
    return 1
  fi

  sudoers_name="90-collavre-${prior//[^A-Za-z0-9_-]/_}"
  rm -f "/etc/sudoers.d/$sudoers_name"

  log "WARNING: '$prior' is no longer in docker or sudo but can still log in;" \
      "remove it by hand once you can reach the host as '$current':" \
      "deluser --remove-home $prior"
}

revoke_prior_deploy_user() {
  local current="$1" prior_file="${2:-$STATE_DIR/deploy_user}"
  local set_file="${3:-${prior_file%/*}/deploy_users}" prior kept='' failed=0

  # Not a no-op on the ordinary path: this is what seeds the set on a host the
  # earlier revision provisioned, and what puts $current in it on a first run,
  # so that a *later* rotation has something to revoke.
  record_deploy_user_grant "$current" "$set_file" "$prior_file" || {
    # Returning rather than carrying on: the loop below reads $set_file, and on
    # this path it may not exist. Nothing has been revoked, and the file is
    # left in the state a later run retries from.
    log "WARNING: could not record '$current' in '$set_file'; no account was" \
        "revoked on this run, and the queue is unchanged"
    return 1
  }

  while read -r prior; do
    if [ -z "$prior" ] || [ "$prior" = "$current" ]; then
      # $current holds both groups on purpose. It stays in the set because the
      # run that replaces it is the one that takes them back.
      [ -z "$prior" ] || kept="$kept$prior"$'\n'
      continue
    fi
    # An account that no longer exists cannot hold either group through, so
    # there is nothing left for a later run to retry.
    id -u "$prior" >/dev/null 2>&1 || continue
    if ! revoke_deploy_user_access "$prior" "$current"; then
      kept="$kept$prior"$'\n'
      failed=1
    fi
  done < "$set_file"

  # Rewritten from what the loop kept rather than appended to, so an account
  # that was revoked leaves the set and one that was not stays in it. Both
  # markers are written at the end: the single-name one is what the runbook and
  # refuse_defaulted_config_change read for "who is the deploy user", which is
  # $current whether or not its predecessor could be stripped — the earlier
  # revision pinned it to the predecessor on that path, so a failed revocation
  # also made the host misreport who it belongs to.
  #
  # Both go through write_state_file rather than a redirection. Neither failure
  # is fatal, and they fail in opposite but safe directions, which is why this
  # warns rather than dies at a point the grants have already happened: the
  # queue keeps its previous contents, so it still names everyone unrevoked and
  # a later run re-reads two group lists for accounts already stripped; the
  # single-name marker keeps naming the predecessor, so the next run's
  # refuse_defaulted_config_change sees a disagreement it was not given and
  # stops. Stale-and-conservative in both cases — where a truncated file is
  # neither.
  write_state_file "$set_file" "$kept" ||
    {
      log "WARNING: could not rewrite the deploy-user queue at '$set_file'; it still" \
	  "lists accounts this run revoked, which costs the next run a re-check"
      failed=1
    }
  [ "$failed" -eq 0 ] || {
    log "WARNING: the SSH cutover is still pending because at least one" \
	"predecessor retains privileged access"
    return 1
  }
  write_state_file "$prior_file" "$current"$'\n' ||
    {
      log "WARNING: could not record '$current' as the deploy user in '$prior_file';" \
	  "the cutover remains pending and can be retried"
      return 1
    }
}

# stage_ssh_cutover <user> <key>
#
# Provisioning may grant the successor access, but it must not infer that access
# works from sshd configuration. Instead it writes a one-time challenge and
# installs this script as the finalizer. The challenge is accepted only when
# the finalizer is reached through an sshd descendant running under the staged
# account. Until then deploy_user, predecessor groups, predecessor sudoers and
# predecessor managed keys all stay unchanged.
stage_ssh_cutover() {
  local user="$1" key="$2" current='' prior_key='' need=0
  local nonce nonce_hash pending="$STATE_DIR/ssh_cutover.pending"
  local key_file="$STATE_DIR/ssh_cutover.key"
  local finalizer="${3:-/usr/local/sbin/collavre-finalize-ssh-cutover}"
  local source="${4:-${BASH_SOURCE[0]}}"

  [ -s "$STATE_DIR/deploy_user" ] &&
    current="$(grep -v '^[[:space:]]*$' "$STATE_DIR/deploy_user" | head -1)"
  [ "$current" = "$user" ] || need=1

  if [ -n "$key" ]; then
    [ -s "$STATE_DIR/ssh_public_key.$user" ] &&
      prior_key="$(cat "$STATE_DIR/ssh_public_key.$user")"
    [ "$prior_key" = "$key" ] || need=1
  fi

  if [ "$need" -eq 0 ]; then
    [ ! -f "$pending" ] ||
      die "an SSH cutover is already pending in $pending. Finalize it from the" \
	  "staged account before another provisioning run."
    SSH_CUTOVER_PENDING=0
    SSH_CUTOVER_NONCE=''
    return 0
  fi

  if [ -s "$pending" ]; then
    local pending_user
    pending_user="$(sed -n 's/^user=//p' "$pending")"
    [ "$pending_user" = "$user" ] ||
      die "an SSH cutover to '$pending_user' is already pending. Finalize that" \
	  "cutover before staging '$user'; no predecessor access was revoked."
  fi

  nonce="$(od -An -N32 -tx1 /dev/urandom | tr -d '[:space:]')"
  [ "${#nonce}" -eq 64 ] || die "could not generate the SSH cutover challenge"
  nonce_hash="$(printf '%s' "$nonce" | sha256sum | awk '{print $1}')"

  write_state_file "$key_file" "$key"$'\n' 0600 ||
    die "could not stage the SSH cutover key in $key_file"
  write_state_file "$pending" \
    "user=$user"$'\n'"nonce_sha256=$nonce_hash"$'\n' 0600 ||
    die "could not stage the SSH cutover challenge in $pending"

  [ -r "$source" ] ||
    die "cannot install the SSH cutover finalizer because $source" \
	"is not readable. Run this script from a file, not a consumed pipe."
  install -m 0755 "$source" "$finalizer"

  SSH_CUTOVER_PENDING=1
  SSH_CUTOVER_NONCE="$nonce"
  log "SSH cutover to '$user' is staged. The predecessor remains privileged" \
      "until the nonce is finalized from an actual SSH session as '$user'."
}

ssh_cutover_has_sshd_ancestor() {
  local user="$1" pid="${2:-$PPID}" comm ppid real_uid target_uid hops=0
  local saw_sshd=0 saw_user=0
  target_uid="$(id -u "$user" 2>/dev/null)" || return 1
  while [ "$pid" -gt 1 ] 2>/dev/null && [ "$hops" -lt 64 ]; do
    comm="$(cat "/proc/$pid/comm" 2>/dev/null || true)"
    case "$comm" in sshd|sshd-session) saw_sshd=1 ;; esac
    real_uid="$(awk '/^Uid:/{print $2}' "/proc/$pid/status" 2>/dev/null || true)"
    [ "$real_uid" = "$target_uid" ] && saw_user=1
    ppid="$(awk '/^PPid:/{print $2}' "/proc/$pid/status" 2>/dev/null || true)"
    case "$ppid" in ''|*[!0-9]*) break ;; esac
    pid="$ppid"
    hops=$((hops + 1))
  done
  [ "$saw_sshd" -eq 1 ] && [ "$saw_user" -eq 1 ]
}

finalize_ssh_cutover() {
  local nonce="${1:-}" pending="$STATE_DIR/ssh_cutover.pending"
  local key_file="$STATE_DIR/ssh_cutover.key" user expected actual

  [ -s "$pending" ] || die "no SSH cutover is pending"
  user="$(sed -n 's/^user=//p' "$pending")"
  expected="$(sed -n 's/^nonce_sha256=//p' "$pending")"
  [ -n "$user" ] && [ -n "$expected" ] ||
    die "$pending is incomplete; predecessor access was not changed"
  [ "${SUDO_USER:-}" = "$user" ] ||
    die "finalize this cutover by SSHing as '$user' and running sudo there;" \
	"SUDO_USER is '${SUDO_USER:-unset}'"
  ssh_cutover_has_sshd_ancestor "$user" ||
    die "no sshd ancestor was found. The cutover must be finalized inside an" \
	"actual SSH session as '$user', not from a local shell or console."
  actual="$(printf '%s' "$nonce" | sha256sum | awk '{print $1}')"
  [ "$actual" = "$expected" ] ||
    die "the SSH cutover nonce is incorrect; predecessor access was not changed"
  in_group "$user" sudo && in_group "$user" docker ||
    die "'$user' no longer has both sudo and docker; predecessor access was" \
	"not changed. Re-run provisioning to repair the staged account."

  APP_SSH_USER="$user"
  APP_HOME="$(getent passwd "$user" | cut -d: -f6)"
  [ -n "$APP_HOME" ] || die "could not resolve the home directory for '$user'"
  APP_SSH_GROUP="$(id -gn "$user")"
  AUTH_KEYS="$APP_HOME/.ssh/authorized_keys"
  [ -s "$AUTH_KEYS" ] ||
    die "$AUTH_KEYS is empty; predecessor access was not changed"

  SSH_PUBLIC_KEY="$(cat "$key_file" 2>/dev/null || true)"
  if [ -n "$SSH_PUBLIC_KEY" ]; then
    grep -qxF "$SSH_PUBLIC_KEY" "$AUTH_KEYS" ||
      die "the staged key is no longer in $AUTH_KEYS; predecessor access was" \
	  "not changed"
    revoke_prior_ssh_key "$AUTH_KEYS"
    [ "$(cat "$STATE_DIR/ssh_public_key.$user" 2>/dev/null || true)" = \
      "$SSH_PUBLIC_KEY" ] ||
      die "the staged key could not be committed; the cutover remains pending"
  fi

  revoke_prior_deploy_user "$user" ||
    die "one or more predecessor accounts could not be disarmed. The cutover" \
	"remains pending; repair the reported account and run this command again."

  rm -f "$pending" "$key_file"
  log "SSH cutover finalized from an authenticated session as '$user'." \
      "KAMAL_SSH_USER may now be changed to '$user'."
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
  local file="${1:-/etc/docker/daemon.json}" tmp driver max_size wrote
  DAEMON_JSON_CHANGED=0
  # Before either branch, so the create path and the rewrite path name one file
  # even when /etc/docker/daemon.json is a link — and so the rename below cannot
  # replace the link itself.
  file="$(resolve_symlink_chain "$file")" || exit 1

  # An existing but empty daemon.json is treated as absent, and this is the read
  # side of the same accident — it repairs hosts the staged create below can
  # only stop from happening again. Truncate-at-open is what a failed `cat >`
  # leaves, so 0 bytes is the likely damage, and it is the one size the rewrite
  # path cannot see: `jq empty` exits 0 on an empty file, and
  # `."log-driver" // "json-file"` comes back as the empty string rather than
  # the default, so the run reports "log-driver is '', which rotates on its own"
  # — an all-clear over a host whose container logs are uncapped, which is the
  # one failure this function exists to prevent.
  #
  # Replacing it destroys nothing, which is why this may act where the
  # invalid-JSON branch below must not: a partial file may hold half of an
  # operator's configuration and nothing distinguishes it from a file this
  # script tore, but an empty one holds no decision of theirs to lose.
  if [ -f "$file" ] && [ ! -s "$file" ]; then
    log "$file exists but is empty — that is what an interrupted create leaves," \
        "not a configuration, so it is being written afresh"
    rm -f "$file"
  fi

  if [ ! -f "$file" ]; then
    # Staged and renamed, like the rewrite below. `cat > "$file"` opens the live
    # path with O_TRUNC, so a write cut short by a full disk or a kill leaves a
    # partial daemon.json that no later run repairs — the retry finds the file
    # present, so it takes the rewrite path, where every branch declines:
    #
    #   live file after a torn create   what the operator's retry then says
    #   0 bytes                         "log-driver is '', which rotates on
    #                                    its own; leaving it alone"
    #   20 bytes / 60 bytes             "not valid JSON ... left untouched
    #                                    rather than overwritten — it is not
    #                                    this script's file"
    #
    # The 0-byte row is the likely one, since that is what truncate-at-open
    # leaves when the write fails immediately, and it is the worse of the two:
    # `jq empty` exits 0 on an empty file, `."log-driver" // "json-file"` comes
    # back as the empty string rather than the default, and the run reports the
    # host as having an operator who chose another driver. Not a warning — an
    # all-clear, over a host whose logs are uncapped, which is the one failure
    # this function exists to prevent.
    #
    # The other row is loud but no more repairable, and its message is wrong in
    # the specific way that matters: it is exactly this script's file. Nothing
    # in the rewrite path can tell a partial file this script wrote from an
    # operator's broken one, and it must not guess — which is why the fix is
    # here, keeping the partial file off the live path, rather than there.
    #
    # Indented so no line of the body starts at column 1: the unit tests extract
    # these functions with an awk range that ends at the first column-1 "}", and
    # a bare closing brace in a heredoc would cut the function in half.
    tmp="$(stage_beside "$file")" || {
      log "WARNING: could not stage $file beside itself, so it was NOT created" \
          "and container logs are NOT capped. Create it by hand with" \
          '{"log-driver": "json-file", "log-opts": {"max-size": "10m", "max-file": "3"}}.'
      return 0
    }
    # Checked for what it is supposed to say, not merely for parsing. `jq empty`
    # exits 0 on a zero-length file — the same fact the empty-file repair above
    # rests on — so a staged write that produced nothing would validate and be
    # renamed into place, installing the exact file this whole change exists to
    # keep off the live path. CI found that: a shortened write errors on BSD
    # `head` and succeeds on GNU, so the case passed here for the wrong reason
    # and failed on Linux for the right one.
    # Written first and judged after, because a heredoc body has to follow the
    # line that opens it — folding the check into the same `if` would make the
    # check itself the first line of the JSON.
    wrote=1
    cat > "$tmp" <<'JSON' || wrote=0
    {
      "log-driver": "json-file",
      "log-opts": { "max-size": "10m", "max-file": "3" }
    }
JSON
    if [ "$wrote" = 0 ] ||
       ! jq -e '."log-opts"."max-size" == "10m"' "$tmp" >/dev/null 2>&1; then
      rm -f "$tmp"
      log "WARNING: a staged $file did not come out as the file it was staged" \
          "to be, so it was NOT installed and container logs are NOT capped." \
          "The live path is untouched, so a later run creates it cleanly."
      return 0
    fi
    # No chmod: stage_beside gives a staging file for an absent target the
    # 0644 the old `cat >` produced, and refuses rather than installing at
    # mktemp's 0600 — a daemon.json dockerd cannot read is the same outage by
    # another route.
    mv -f "$tmp" "$file"
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

  # Docker treats max-size=-1 as unlimited, so it is not a cap even though it
  # is a nonempty operator setting. Repair it through the same merge path as a
  # missing max-size; every other explicit size remains the operator's choice.
  max_size="$(jq -r '."log-opts"."max-size" // empty' "$file")"
  if [ -n "$max_size" ] && [ "$max_size" != "-1" ]; then
    return 0
  fi

  # Staged beside the target rather than in $TMPDIR, and installed by rename.
  # The validation below was already right and the install was not: `cat "$tmp"
  # > "$file"` truncates the live daemon.json at open, so an interrupted copy
  # leaves a prefix that jq never sees — the file that was checked is not the
  # file that ends up installed. Measured on the shipped function with the copy
  # failing partway, against an operator's daemon.json holding an
  # insecure-registries entry:
  #
  #   live daemon.json  {"insecure-regist          parses: no
  #
  # And nothing notices: the caller only restarts Docker when this returns
  # having changed the file, so the running daemon keeps the configuration it
  # read at boot and the host looks healthy until something reboots it. Then
  # dockerd will not start, and every `kamal deploy` fails against a host whose
  # last successful run reported success.
  tmp="$(stage_beside "$file")" || {
    log "WARNING: could not stage a rewrite of $file beside it; it is unchanged" \
        "and container logs are NOT capped. Add" \
        '"log-opts": {"max-size": "10m", "max-file": "3"} by hand.'
    return 0
  }
  # Merge rather than replace: everything else in the file is the operator's.
  # Validated before it is installed, because a daemon.json that does not parse
  # stops Docker from starting at all — and validated by asking whether the caps
  # are in it rather than whether it parses, for the same reason as the create
  # branch above: `jq empty` exits 0 on a zero-length file, so "it parses" is an
  # answer an empty staging file also gives.
  if ! jq '."log-driver" = "json-file"
           | ."log-opts" = ((."log-opts" // {})
               + {"max-size": "10m", "max-file": "3"})' "$file" > "$tmp" ||
     ! jq -e '."log-opts"."max-size" == "10m"' "$tmp" >/dev/null 2>&1; then
    rm -f "$tmp"
    log "WARNING: could not merge the log caps into $file; it is unchanged and" \
        "container logs are NOT capped. Add" \
        '"log-opts": {"max-size": "10m", "max-file": "3"} by hand.'
    return 0
  fi
  mv -f "$tmp" "$file"
  log "added container log caps to the existing $file"
  DAEMON_JSON_CHANGED=1
}

# Docker daemon logging options are defaults captured when each container is
# created. Restarting the daemon makes a new default available but does not
# retrofit containers that already exist.
warn_existing_containers_keep_log_config() {
  local containers
  if ! containers="$(docker ps -aq 2>/dev/null)"; then
    log "WARNING: Docker's log defaults changed, but existing containers could" \
	"not be inspected. Any existing container keeps its previous logging" \
	"configuration until it is recreated."
    return 0
  fi
  [ -n "$containers" ] || return 0
  log "WARNING: Docker's log cap is a default for newly created containers only." \
      "Existing containers keep their previous logging configuration. The caps" \
      "apply to them only after the next './kamal.sh deploy' recreates them."
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
  local lsclusters="${1:-pg_lsclusters}" ver cluster port owner_of_default=""
  local name_of_default="" layout=""
  command -v "$lsclusters" >/dev/null 2>&1 || return 0

  # Read into a variable first, so the status is answerable. It used to be
  # expanded straight into the here-document below, where the command
  # substitution's status is discarded: a `pg_lsclusters` that exits non-zero
  # with nothing on stdout gave an empty loop, and a `while` whose body never
  # runs completes with status 0. The guard then read the host as having no
  # clusters at all — its one PROCEED answer — which is the reverse of what an
  # unreadable layout means. Measured: a stub that exits 1 silently PROCEEDs,
  # and so does one that exits 1 after printing only some of the clusters, on a
  # host where another major version owns 5432.
  #
  # Assigned on its own line rather than in the `local` above, because `local
  # x="$(...)"` returns the status of `local` and would discard it a second way.
  #
  # Empty output with status 0 still proceeds, and must: postgresql-common is
  # installed here before any cluster exists, and `pg_lsclusters -h` on that
  # host is legitimately silent. Emptiness is not the signal — the status is.
  layout="$("$lsclusters" -h 2>/dev/null)" ||
    die "'$lsclusters -h' failed on this host, so this run cannot tell which" \
        "PostgreSQL clusters exist or which one serves $DB_PORT. Carrying on" \
        "would read that failure as 'no clusters', install $PG_MAJOR, and write" \
        "listen_addresses, the tuning and the pg_hba rule into" \
        "/etc/postgresql/$PG_MAJOR/main while an existing cluster kept serving" \
        "$DB_PORT — the layout this check exists to refuse. Nothing has been" \
        "changed. Run 'pg_lsclusters' by hand to see why it failed."

  while read -r ver cluster port _rest; do
    [ -n "$ver" ] || continue
    if [ "$port" = "$DB_PORT" ]; then
      owner_of_default="$ver"
      name_of_default="$cluster"
    fi
    if [ "$ver" = "$PG_MAJOR" ] && [ "$port" != "$DB_PORT" ]; then
      die "PostgreSQL $PG_MAJOR is installed but its 'main' cluster listens on $port, not $DB_PORT." \
          "This script only supports a single cluster on $DB_PORT — DATABASE_URL, the ufw rule" \
          "and the nightly backup all name it. Move it with 'pg_ctlcluster' /" \
          "'/etc/postgresql/$PG_MAJOR/main/postgresql.conf', or set PG_MAJOR to the version" \
          "already serving $DB_PORT."
    fi
  done <<EOF
$layout
EOF

  if [ -n "$owner_of_default" ] && [ "$owner_of_default" != "$PG_MAJOR" ]; then
    die "PostgreSQL $owner_of_default already serves $DB_PORT on this host, and PG_MAJOR is $PG_MAJOR." \
        "Installing $PG_MAJOR now would create its cluster on the next free port while the app," \
        "the backups and DATABASE_URL kept using $DB_PORT — a version bump that silently does not" \
        "happen. Either set PG_MAJOR=$owner_of_default, or migrate deliberately with" \
        "'pg_upgradecluster $owner_of_default main' and drop the old cluster before re-running."
  fi

  # The version and the port agreeing is not enough: everything below names the
  # cluster *directory*, and it names it 'main'. pg_createcluster's default name
  # is 'main', so this is only reachable on a host where someone created the
  # cluster by hand with --datadir or -o, but there it fails in silence rather
  # than loudly. `/etc/postgresql/$PG_MAJOR/main` is absent, so the apt install
  # at step 5 runs and reports the package already present without creating a
  # second cluster; `install -d` then makes the missing directory, the tuning,
  # listen_addresses and the pg_hba rule for the docker bridge are all written
  # into a tree no postmaster reads, and `systemctl restart postgresql` restarts
  # the real cluster — successfully, because the umbrella unit does not care
  # which clusters exist. Nothing fails. The containers then cannot reach the
  # database, because listen_addresses was never actually set on the cluster
  # that is running.
  #
  # Naming the discovered path instead would mean threading it through the
  # backup unit and the runbook's recovery blocks, which spell
  # /etc/postgresql/<major>/main as literal text an operator pastes.
  if [ -n "$name_of_default" ] && [ "$name_of_default" != main ]; then
    die "The PostgreSQL $owner_of_default cluster serving $DB_PORT is named '$name_of_default', not 'main'." \
        "This script writes listen_addresses, the tuning and the pg_hba rule for the docker bridge" \
        "into /etc/postgresql/$PG_MAJOR/main, and the runbook's recovery steps name that path too —" \
        "against a cluster called '$name_of_default' all of it would be written where no postmaster" \
        "reads it, the run would report success, and the containers would still be unable to reach" \
        "the database. Move the cluster to the standard name with" \
        "'pg_renamecluster $owner_of_default $name_of_default main', or provision this app on a host" \
        "whose $DB_PORT cluster is 'main'."
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
  local current="$1" prior_file="${2:-$STATE_DIR/db_user}" prior owns exists super
  [ -f "$prior_file" ] || return 0
  prior="$(cat "$prior_file")"
  [ -n "$prior" ] && [ "$prior" != "$current" ] || return 0

  # Both probes keep their status, for the reason role_owns_app_objects states
  # two functions up and this one did not apply to itself: an unanswerable
  # question has to read as the unsafe answer. Under the earlier
  # `[ "$(psql ...)" = 1 ] || return 0` a psql that could not answer produced an
  # empty string, which is neither "1" nor "t", so a dead connection read as
  # "no such role" and then as "not a superuser" — and the guard passed the run
  # it exists to stop. Measured against 6125e4ee on a host recorded as
  # DB_USER=postgres owning 7 objects, each query failed in turn:
  #
  #   failing query      guard
  #   --                 REFUSES
  #   count(*)           PROCEEDS
  #   rolsuper           PROCEEDS
  #   pg_get_userbyid    REFUSES     (the one path that already checked)
  #
  # Proceeding is not a deferred refusal. This guard is called before the SQL
  # block on purpose — `ALTER DATABASE ... OWNER TO` runs at that point, and
  # reassign_prior_db_role only afterwards — so a bypass moves the stop from
  # "nothing has been changed" to a host whose database belongs to the new role
  # while every table in it still belongs to the superuser. That is the half-
  # rotated state the pre-check exists to make unreachable.
  #
  # die() rather than a bare non-zero: this runs after PostgreSQL is up, so a
  # cluster that cannot answer here also cannot run the SQL block below, and
  # the run is going to stop either way. Stopping with the reason, before
  # anything is written, is the difference worth having.
  exists="$(psql_as_postgres postgres \
    "SELECT count(*) FROM pg_roles WHERE rolname = '$prior'")" ||
    die "could not ask the cluster whether the previous DB_USER '$prior' still" \
        "exists, so this run cannot tell a completed rotation from one that would" \
        "strand every table with a superuser. Nothing has been changed. Check that" \
        "PostgreSQL is accepting connections on port $DB_PORT and re-run."
  [ "$exists" = 1 ] || return 0
  super="$(psql_as_postgres postgres \
    "SELECT rolsuper FROM pg_roles WHERE rolname = '$prior'")" ||
    die "could not ask the cluster whether the previous DB_USER '$prior' is a" \
        "superuser, whose objects PostgreSQL refuses to reassign. Nothing has been" \
        "changed. Check that PostgreSQL is accepting connections on port $DB_PORT" \
        "and re-run."
  [ "$super" = t ] || return 0

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

# record_db_role_grant <role> [set file] [legacy single marker]
#
# The same shape as record_deploy_user_grant, one resource over, and for the
# same reason: db_user is a single marker, so it can name the role this host is
# *currently* deployed against or the queue of roles a rotation has not finished
# retiring, but not both.
#
# The interrupted A -> B -> C sequence is what it cannot survive. Ownership is
# moved by reassign_prior_db_role and the marker is advanced on the next line;
# a run that dies between them leaves every table owned by B while db_user still
# says A. If the operator's next run asks for C rather than replaying B, the
# rotation reads A as the predecessor, reassigns from a role that owns nothing,
# moves no objects, records C, and the summary hands out a DATABASE_URL for a
# role that cannot read a row. Measured against 07365195:
#
#   run2  A -> B, dies before the marker write   objects: B   db_user: A
#   run3  C                                      objects: B   db_user: C
#
# Nothing on the host names B at that point, so no later run can find it either.
# Called before the role is made an owner, not after, for the same reason the
# deploy-user version is called before the grant: a name in this file that turns
# out to own nothing costs one cheap query, and a name missing from it is a
# database whose owner nothing is looking for.
record_db_role_grant() {
  local role="$1" set_file="${2:-$STATE_DIR/db_users}"
  local prior_file="${3:-$STATE_DIR/db_user}"
  # Upgrade path, as for deploy_users: on a host provisioned by the earlier
  # revision the single marker names the one predecessor it knew about, and
  # seeding from it means the fix for forgetting roles does not start by
  # forgetting one. Guarded on `! -f`, so it runs once per host — the write is
  # therefore all-or-nothing, and a failed seed leaves the file absent for a
  # retry rather than empty and authoritative.
  if [ ! -f "$set_file" ] && [ -s "$prior_file" ]; then
    local seed
    seed="$(grep -v '^[[:space:]]*$' "$prior_file")" || seed=''
    if [ -n "$seed" ]; then
      write_state_file "$set_file" "$seed"$'\n' || return 1
    fi
  fi
  append_state_line "$set_file" "$role"
}

# reassign_one_db_role <prior> <current>
#
# Moves one replaced role's objects. Returns 0 when there is nothing left for a
# later run to do with <prior>, non-zero when it must stay in the queue — so the
# caller decides what is still outstanding, rather than this deciding it by
# where it writes a marker.
reassign_one_db_role() {
  local prior="$1" current="$2" exists super owns

  # Every psql status below is checked explicitly rather than left to `set -e`.
  # This function is called from `... || kept="$kept$prior"`, and a function
  # invoked on the left of `||` runs with errexit suppressed for its whole
  # body — so under `set -e` alone a failed REASSIGN fell through to
  # ALTER ROLE ... NOLOGIN and returned the status of the last log: zero.
  # Measured on the previous revision with the REASSIGN made to fail:
  #
  #   log: moved ownership of everything in 'db' from 'A' to 'B'
  #   log: revoked LOGIN from the replaced database role 'A'
  #   rc=0   objects still owned by A   NOLOGIN applied to A   queue: [B]
  #
  # which is the state the queue exists to prevent, reached by the one path
  # that reports success: A still owns every table and can no longer log in,
  # B is published in DATABASE_URL owning nothing, and A has just been dropped
  # from the only record that named it.
  #
  # The probes are checked for the same reason as the statements: an empty
  # result from a connection that died reads as "no such role" or "not a
  # superuser", and both of those retire the role from the queue.

  # A role that no longer exists owns nothing and cannot be reassigned: there
  # is nothing outstanding, so it leaves the queue.
  exists="$(psql_as_postgres postgres \
    "SELECT count(*) FROM pg_roles WHERE rolname = '$prior'")" || return 1
  [ "$exists" = 1 ] || return 0

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
  super="$(psql_as_postgres postgres \
    "SELECT rolsuper FROM pg_roles WHERE rolname = '$prior'")" || return 1
  if [ "$super" = t ]; then
    owns="$(role_owns_app_objects "$DB_NAME" "$prior")" || return 1
    if [ "$owns" = 0 ]; then
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

  psql_as_postgres "$DB_NAME" "REASSIGN OWNED BY \"$prior\" TO \"$current\"" || {
    log "WARNING: could not move ownership in '$DB_NAME' from '$prior' to" \
        "'$current'. '$prior' still owns those objects and keeps LOGIN, and it" \
        "stays queued for a later run. REASSIGN OWNED is one transaction, so" \
        "nothing was moved by half."
    return 1
  }
  log "moved ownership of everything in '$DB_NAME' from '$prior' to '$current'"

  # Checked separately from the REASSIGN, because by here ownership has already
  # moved: staying queued retries a REASSIGN that is now a no-op and this
  # statement, which is the one that did not take.
  psql_as_postgres postgres "ALTER ROLE \"$prior\" NOLOGIN" || {
    log "WARNING: ownership in '$DB_NAME' moved to '$current', but LOGIN could" \
        "not be revoked from '$prior', which can still connect with the" \
        "password it was given. It stays queued for a later run."
    return 1
  }
  log "revoked LOGIN from the replaced database role '$prior'"
}

reassign_prior_db_role() {
  local current="$1" prior_file="${2:-$STATE_DIR/db_user}"
  local set_file="${3:-${prior_file%/*}/db_users}" prior kept='' outstanding=0

  # Not a no-op on the ordinary path: this seeds the set on a host the earlier
  # revision provisioned, and puts $current in it on a first run, so that a
  # later rotation has something to reassign from.
  record_db_role_grant "$current" "$set_file" "$prior_file" || {
    # Returning rather than carrying on: the loop reads $set_file, which on
    # this path may not exist. Nothing has been reassigned, and the file is
    # left in the state a later run retries from.
    log "WARNING: could not record '$current' in '$set_file'; no database role" \
        "was reassigned on this run, and the queue is unchanged"
    return 1
  }

  while read -r prior; do
    [ -n "$prior" ] || continue
    # The role this run deploys against stays in the set: it is the predecessor
    # the *next* rotation reassigns from.
    if [ "$prior" = "$current" ]; then
      kept="$kept$prior"$'\n'
      continue
    fi
    reassign_one_db_role "$prior" "$current" || {
      kept="$kept$prior"$'\n'
      outstanding=1
    }
  done < "$set_file"

  # Rewritten only after the loop, from $kept — every role this run did not
  # finish retiring. What stood here before was wrong, and wrong in the
  # direction that mattered: it said a failed REASSIGN "takes the run down
  # under `set -e`". It does not. The call above is on the left of `||`, which
  # suppresses errexit inside the function for its whole body, so nothing takes
  # the run down and the entry was consumed anyway. The propagation is explicit
  # in reassign_one_db_role now, and it is what puts $prior back in $kept.
  write_state_file "$set_file" "$kept" ||
    log "WARNING: could not rewrite '$set_file'. Ownership was moved, but this" \
        "host still lists roles a later run will try to reassign again;" \
        "REASSIGN OWNED BY on a role that owns nothing is a no-op, so the retry" \
        "is harmless. Check that $STATE_DIR has space."

  # Non-zero when a role is still outstanding, and reported after the queue has
  # been written so the retry has something to read. The call site runs this
  # bare under `set -e`, which is where the propagation has to end up: the run
  # stops here rather than at the summary, so $STATE_DIR/db_user is not advanced
  # and no DATABASE_URL is printed for a role that may own none of the tables.
  # A WARNING would not do — what continues past it is a deployment against a
  # role that gets "permission denied" on its own data.
  [ "$outstanding" = 0 ]
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

  # Read into a variable rather than branching on the file, because an empty
  # marker is not the same question as an absent one and must not answer it.
  # A truncated db_name says "a name was recorded and this run cannot read it",
  # which is exactly the case the no-record path below is built to catch; the
  # earlier form returned 0 from inside the `-f` branch, so an empty file
  # skipped both this comparison and that fallback, and the guard passed
  # anything.
  prior=''
  [ -f "$state_dir/db_name" ] && prior="$(cat "$state_dir/db_name")"

  if [ -n "$prior" ]; then
    [ "$prior" != "$current" ] || return 0
    die "this host was provisioned with DB_NAME='$prior', and DB_NAME is now" \
        "'$current'. This script creates a database if it is missing; it does not" \
        "rename or copy one, so '$current' would be created empty while the app's" \
        "data stayed in '$prior' — and the summary, DATABASE_URL and the nightly" \
        "backup would all name the empty one. Nothing has been changed. Set" \
        "DB_NAME='$prior', or move the data deliberately — see 'Changing DB_NAME" \
        "on a re-run' in docs/deploy_to_lightsail.md."
  fi

  # No usable record — absent, or present but unreadable. On a genuine first run
  # there is nothing to protect, and adopting the name is right. On a host
  # provisioned by a revision that did not track it there is: db_user is the
  # marker that says this script has run here before.
  [ -f "$state_dir/db_user" ] || return 0
  # The status is kept, for the reason role_owns_app_objects states and the
  # superuser guard one commit ago had to be taught: this compares *output*, so
  # a psql that could not answer produces an empty string, which is not "0" —
  # and the `|| return 0` then reads "I could not ask" as "the database is
  # already there". Measured against e16bd114 on a host recorded as provisioned,
  # asked for a database that does not exist:
  #
  #   probe answers        REFUSES
  #   probe cannot answer  PROCEEDS
  #
  # Proceeding is not a deferred refusal. This guard runs before the creation
  # SQL, so a bypass on a run where PostgreSQL comes back a moment later creates
  # the typo'd database empty, advances db_name and db_user to it, and points
  # DATABASE_URL and the nightly pg_dump at it — while the app's data sits in
  # the database nothing now names. That is precisely the outcome the refusal
  # exists to make unreachable, and it is reached by way of the check.
  local existing
  existing="$(psql_as_postgres postgres \
    "SELECT count(*) FROM pg_database WHERE datname = '$current'")" ||
    die "this host has been provisioned before, but the cluster would not say" \
        "whether DB_NAME='$current' exists on it — so this run cannot tell a" \
        "first use of a new name from a typo that would be created empty beside" \
        "the app's real data. Nothing has been changed. Check that PostgreSQL is" \
        "accepting connections on port $DB_PORT, then re-run."
  [ "$existing" = 0 ] || return 0

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

  # An empty marker is not an absent one, and the difference is not recoverable
  # here. write_state_file never produces one, so a marker that exists and holds
  # nothing means a revision that wrote it by redirection was interrupted — and
  # the rule that was in force at that moment is still in force, with nothing
  # naming it. Unlike db_name there is no second record to fall back to: `ufw
  # status` renders rules in a display form that `ufw delete` does not accept,
  # which is why this marker exists at all. So it is said out loud rather than
  # passed over, which is the whole of what this run can do about it.
  if [ -f "$state" ] && [ -z "$prior" ]; then
    log "WARNING: the $name rule marker '$state' exists but is empty, which an" \
        "interrupted write by an earlier revision leaves behind. A rule this" \
        "script added may still be in force with no record of it — check" \
        "'ufw status numbered' for a $name rule you did not ask for on this run."
  fi

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

  # Through write_state_file, not a redirection. `>` truncates when it opens, so
  # an interrupted write leaves the marker present and empty — and the read at
  # the top of this function branches on `[ -n "$prior" ]`, so an empty marker
  # is not a degraded record, it is *no* record: the withdrawal block is skipped
  # entirely and the rule installed on that run stays in force with nothing on
  # the host naming it. Measured on the extracted function, marker emptied after
  # the first converge and the subnet then changed twice:
  #
  #   rule: allow from 172.17.0.0/16 to any port 5432 proto tcp   <- stranded
  #   rule: allow from 10.0.9.0/24   to any port 5432 proto tcp
  #   marker: allow from 10.0.9.0/24 to any port 5432 proto tcp
  #
  # Exactly one rule is stranded — the one in force when the write was cut — and
  # it is permanent: every later run withdraws what the marker names, which has
  # moved past it. For the postgres rule that is an obsolete Docker subnet still
  # reaching 5432 for the life of the instance.
  #
  # A failed write is warned about rather than fatal, and names the rule: the
  # grant has already happened, so dying here would leave the same untracked
  # rule with less said about it. The previous marker survives, which strands
  # this one at the *next* change rather than immediately — worth saying out
  # loud, because it is the one case this function cannot make self-healing.
  write_state_file "$state" "$rule"$'\n' ||
    log "WARNING: the $name rule is in force but could NOT be recorded in" \
        "'$state': $rule — a later run that changes it will withdraw the rule" \
        "this file still names and leave this one authorized. Re-run to record" \
        "it, or remove it by hand with: ufw delete $rule"
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
#
# And the direction, which is the one this got wrong. `ufw status` renders an
# inbound rule with a bare action and puts the direction in the action column
# only when it is not inbound — there is no "ALLOW IN" in this output. So a rule
# that authorizes nothing inbound reads exactly like one that does, apart from a
# word the pattern did not look at. Measured against real ufw on ubuntu:24.04,
# one `ufw status` per row, the shipped pattern beside the direction-aware one:
#
#   ufw status shows                 shipped   with the filter   the run then
#   22/tcp      ALLOW OUT            YES       no                adds inbound 22
#   OpenSSH     ALLOW OUT            YES       no                adds inbound 22
#   22/tcp ALLOW OUT + 80/tcp ALLOW  YES       no                adds inbound 22
#   22/tcp      ALLOW                YES       YES               leaves it alone
#   OpenSSH     ALLOW                YES       YES               leaves it alone
#   22/tcp      LIMIT                YES       YES               leaves it alone
#   22 from 203.0.113.7  ALLOW       YES       YES               leaves it alone
#   80/tcp only                      no        no                adds inbound 22
#   22/tcp      DENY                 no        no                adds inbound 22
#
# The first three rows are the failure and the four after them are why the fix
# is a filter rather than a stricter pattern: an operator who narrowed 22 to one
# source, or used the OpenSSH profile, or rate-limited it, must still be left
# alone. Getting those wrong broadens the rule this function exists to protect.
#
# The consequence of the first row is the worst outcome this script has. `ufw
# default deny incoming` is applied and ufw is enabled a few steps later, so a
# host whose only port-22 rule is *outbound* has SSH read as authorized, no
# inbound rule added, and the firewall turned on — locking out the operator who
# is running this over SSH at the time, on an instance whose console is the only
# way back in.
#
# FWD as well as OUT: `ufw route allow ... port 22` renders "22/tcp ALLOW FWD",
# which is a rule about traffic passing *through* this host and authorizes
# nothing arriving at it. Confirmed in the same run as the table above.
ssh_already_allowed() {
  ufw status 2>/dev/null |
    sed 's/#.*//' |
    grep -vE '\(v6\)|:' |
    grep -vE '(ALLOW|LIMIT|DENY|REJECT)[[:space:]]+(OUT|FWD)' |
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

# The finalizer is an installed copy of this script. Dispatch only after every
# helper has been defined, but before the normal provisioning guards and any
# host mutation. Its caller must be the staged account inside a real SSH
# session; finalize_ssh_cutover verifies both conditions again.
if [ "${1:-}" = "--finalize-ssh-cutover" ]; then
  finalize_ssh_cutover "${2:-}"
  exit 0
fi

# Before refuse_defaulted_config_change, and long before anything is installed:
# a value this script cannot use is not usable whatever the host was given
# earlier, so it is answered without reading any state at all.
refuse_unusable_db_identifier DB_NAME "$DB_NAME"
refuse_unusable_db_identifier DB_USER "$DB_USER"
refuse_unusable_bind_address DB_BIND_ADDRESS "$DB_BIND_ADDRESS"
refuse_unusable_subnet DOCKER_SUBNETS "$DOCKER_SUBNETS"
refuse_unusable_retention BACKUP_RETENTION_DAYS "$BACKUP_RETENTION_DAYS"
refuse_unusable_backup_calendar BACKUP_AT "$BACKUP_AT" "$BACKUP_CALENDAR"
refuse_unparsable_ssh_key
refuse_forced_command_ssh_key
refuse_root_deploy_user "$APP_SSH_USER"
refuse_nologin_deploy_user "$APP_SSH_USER"

if [ -f "$MARKER" ] && [ "${FORCE:-0}" != "1" ]; then
  log "already provisioned ($MARKER). Re-run with FORCE=1 to converge again."
  exit 0
fi

refuse_defaulted_config_change

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
# Staged and renamed, for the same reason the SSH drop-in in step 3 is. A `>`
# here truncates the live file before it writes, and a run killed between the
# two leaves a sysctl drop-in that `sysctl --system` reads without complaint —
# it applies whichever lines survived and says nothing about the ones that did
# not. Losing net.ipv4.ip_nonlocal_bind that way is the quiet one: everything
# works until the next reboot, and then PostgreSQL cannot bind the docker0
# address if it starts before dockerd, which is the failure the whole
# DB_BIND_ADDRESS thread on this file is about.
install_managed_config 'the sysctl drop-in' /etc/sysctl.d/99-collavre.conf \
  '# Prefer RAM, use swap only under real pressure.' \
  'vm.swappiness = 10' \
  'vm.vfs_cache_pressure = 50' \
  '# Let PostgreSQL bind the docker0 gateway address even when the bridge has' \
  '# not been created yet (PostgreSQL can start before dockerd after a reboot).' \
  'net.ipv4.ip_nonlocal_bind = 1'
sysctl --system >/dev/null

# verify_ssh_hardening [effective config file] [sshd config dir]
#                      [reload state: 0=reloaded, 2=no active daemon]
#                      [deploy user] [require readable result]
#
# Read back what sshd actually resolved the hardened authentication settings
# to, and refuse a run that reported hardening it did not perform. Password,
# root and keyboard-interactive authentication must be off; public-key
# authentication must remain on because it is the deploy account's only way in.
#
# Naming the drop-in so it sorts first is necessary and not sufficient: a
# directive above the Include in sshd_config itself, or an operator's own
# drop-in with an earlier prefix, still wins, and the file name says nothing
# about either. The only thing that answers is sshd's own resolution of the
# whole configuration.
#
# Refusing rather than warning. The first call is at the top of step 3, before
# the deploy account is created or armed; later calls repeat the same check
# after each group grant because Match Group is evaluated against the account's
# membership at connection time. The alternative is a run that prints its
# summary over a privileged account still accepting passwords.
#
# An answer that cannot be read is not the same as a wrong one when a running
# daemon has just accepted the reload, and is warned about instead. With no
# active daemon it is the only gate: the next socket-activated connection will
# start sshd from those files, so an unreadable answer is fatal in reload state
# 2. `sshd -T` needs host keys and a parseable configuration. `-C user=...` is
# load-bearing: without it sshd prints only the global block, so a later
# `Match User <deploy-user>` can turn password authentication back on while
# this verifier reports the global `no`.
#
# scan_ssh_config_file <file> <relative-include root>
#
# Follow Include directives in the order sshd reads them while carrying Match
# state across file boundaries. A flat grep cannot do that: Include is textual,
# so an address-scoped Match before an Include also scopes authentication
# directives inside the included file, and Match All after it ends the scope.
scan_ssh_config_file() {
  local file="$1" include_root="$2" canonical old_stack line raw_line key value
  local pattern included line_no=0 i
  local -a fields=()
  [ -f "$file" ] || return 0

  canonical="$(realpath "$file" 2>/dev/null || printf '%s' "$file")"
  case $'\n'"${SSH_CONFIG_SCAN_STACK:-}"$'\n' in
    *$'\n'"$canonical"$'\n'*)
      SSH_CONFIG_SCAN_UNSAFE="$canonical: recursive Include"
      return 0
      ;;
  esac
  old_stack="${SSH_CONFIG_SCAN_STACK:-}"
  SSH_CONFIG_SCAN_STACK="${SSH_CONFIG_SCAN_STACK:-}${SSH_CONFIG_SCAN_STACK:+$'\n'}$canonical"

  while IFS= read -r line || [ -n "$line" ]; do
    line_no=$(( line_no + 1 ))
    raw_line="$line"
    # OpenSSH accepts quoting and backslash escapes in Include paths. Reusing
    # shell parsing here would be wrong (and eval would execute the config), so
    # fail closed on those uncommon forms rather than split them into the wrong
    # paths and silently skip a contextual authentication override.
    if [[ "$raw_line" =~ ^[[:space:]]*[Ii][Nn][Cc][Ll][Uu][Dd][Ee][[:space:]] ]] &&
       { [[ "$raw_line" = *\"* ]] || [[ "$raw_line" = *\\* ]]; }; then
      SSH_CONFIG_SCAN_UNSAFE="$canonical:$line_no: quoted or escaped Include cannot be verified"
      break
    fi
    line="${line%%#*}"
    read -ra fields <<<"$line"
    [ "${#fields[@]}" -gt 0 ] || continue
    key="$(printf '%s' "${fields[0]}" | tr '[:upper:]' '[:lower:]')"

    if [ "$key" = include ]; then
      for pattern in "${fields[@]:1}"; do
	pattern="${pattern#\"}"
	pattern="${pattern%\"}"
	[[ "$pattern" = /* ]] || pattern="$include_root/$pattern"
	while IFS= read -r included; do
	  scan_ssh_config_file "$included" "$include_root"
	  [ -z "${SSH_CONFIG_SCAN_UNSAFE:-}" ] || break 3
	done < <(compgen -G "$pattern" | LC_ALL=C sort)
      done
      continue
    fi

    if [ "$key" = match ]; then
      SSH_CONFIG_SCAN_CONTEXTUAL=0
      i=1
      while [ "$i" -lt "${#fields[@]}" ]; do
	key="$(printf '%s' "${fields[$i]}" | tr '[:upper:]' '[:lower:]')"
	case "$key" in
	  all)
	    i=$(( i + 1 ))
	    ;;
	  user|group)
	    i=$(( i + 2 ))
	    ;;
	  address|host|localaddress|localnetwork|localport|rdomain)
	    SSH_CONFIG_SCAN_CONTEXTUAL=1
	    i=$(( i + 2 ))
	    ;;
	  *)
	    # A newer or malformed criterion is not something a user-only probe
	    # can prove safe. sshd -T below still supplies the syntax verdict.
	    SSH_CONFIG_SCAN_CONTEXTUAL=1
	    i=$(( i + 1 ))
	    ;;
	esac
      done
      continue
    fi

    if [ "${SSH_CONFIG_SCAN_CONTEXTUAL:-0}" -eq 1 ]; then
      value="${fields[1]:-}"
      value="$(printf '%s' "$value" | tr '[:upper:]' '[:lower:]')"
      case "$key" in
	passwordauthentication|kbdinteractiveauthentication|challengeresponseauthentication|permitrootlogin)
	  [ "$value" = no ] || {
	    SSH_CONFIG_SCAN_UNSAFE="$canonical:$line_no:${line#"${line%%[![:space:]]*}"}"
	    break
	  }
	  ;;
	pubkeyauthentication)
	  [ "$value" = yes ] || {
	    SSH_CONFIG_SCAN_UNSAFE="$canonical:$line_no:${line#"${line%%[![:space:]]*}"}"
	    break
	  }
	  ;;
	authorizedkeysfile|allowusers|denyusers|allowgroups|denygroups)
	  # The user-only effective probe below cannot evaluate a destination
	  # path or admission rule that changes with Address/Host/listener
	  # context. Refuse the ambiguity before the account receives privilege.
	  SSH_CONFIG_SCAN_UNSAFE="$canonical:$line_no:${line#"${line%%[![:space:]]*}"}"
	  break
	  ;;
      esac
    fi
  done < "$file"

  SSH_CONFIG_SCAN_STACK="$old_stack"
}

find_unsafe_ssh_match() {
  local conf_dir="${1:-/etc/ssh}"
  SSH_CONFIG_SCAN_CONTEXTUAL=0
  SSH_CONFIG_SCAN_UNSAFE=""
  SSH_CONFIG_SCAN_STACK=""
  scan_ssh_config_file "$conf_dir/sshd_config" "$conf_dir"
  printf '%s\n' "$SSH_CONFIG_SCAN_UNSAFE"
  unset SSH_CONFIG_SCAN_CONTEXTUAL SSH_CONFIG_SCAN_UNSAFE SSH_CONFIG_SCAN_STACK
}

# verify_ssh_key_destination <effective config file> <user> <home> <target>
#
# Refuse to populate a hard-coded authorized_keys file unless sshd's effective
# AuthorizedKeysFile list for the deploy account includes that exact path.
# Relative paths are resolved below the account's home, matching sshd. The
# common %h, %u and %U tokens are expanded; wildcard paths are deliberately not
# guessed at because proving that a glob selects the target is not enough to
# prove it is the file sshd will safely read under StrictModes.
verify_ssh_key_destination() {
  local src="$1" user="$2" home="$3" target="$4"
  local effective paths path expanded uid sentinel=$'\001'
  if [ -n "$src" ]; then
    effective="$(cat "$src")" ||
      die "SSH AuthorizedKeysFile could not be read for '$user'. Nothing has" \
	  "been granted; correct the test input and re-run."
  elif ! effective="$(sshd -T -C "user=$user" 2>/dev/null)"; then
    die "SSH AuthorizedKeysFile could not be verified for '$user':" \
	"'sshd -T -C user=$user' rejected or could not read the configuration." \
	"Nothing has been granted. Run 'sshd -t', correct the configuration and" \
	"re-run."
  fi

  paths="$(printf '%s\n' "$effective" |
    awk 'tolower($1) == "authorizedkeysfile" {
      for (i = 2; i <= NF; i++) print $i
    }')"
  [ -n "$paths" ] ||
    die "SSH AuthorizedKeysFile could not be verified for '$user': sshd did" \
	"not report the setting. Nothing has been granted. Correct the SSH" \
	"configuration and re-run."

  while IFS= read -r path; do
    case "$path" in
      *'*'*|*'?'*) continue ;;
    esac
    expanded="${path//%%/$sentinel}"
    expanded="${expanded//%h/$home}"
    expanded="${expanded//%u/$user}"
    if [[ "$expanded" = *%U* ]]; then
      uid="$(id -u "$user" 2>/dev/null)" || continue
      expanded="${expanded//%U/$uid}"
    fi
    expanded="${expanded//$sentinel/%}"
    [[ "$expanded" = /* ]] || expanded="${home%/}/$expanded"
    [ "$expanded" = "$target" ] && return 0
  done <<< "$paths"

  die "SSH AuthorizedKeysFile for '$user' does not include '$target'." \
      "Provisioning will not install a key in a file sshd does not read, or" \
      "revoke the previous deploy user's access on that assumption. Restore" \
      "'.ssh/authorized_keys' (or an equivalent %h/%u path) in sshd_config" \
      "and re-run."
}

# ssh_pattern_list_matches <name> <newline-separated patterns> [user]
#
# Apply OpenSSH's positive/negated pattern-list rule for the * and ? forms used
# by AllowUsers/DenyUsers/AllowGroups/DenyGroups. A relevant USER@HOST rule
# other than USER@* cannot be proved from a user-only sshd -T probe and returns
# 2 so the caller can fail closed.
ssh_pattern_list_matches() {
  local name="$1" patterns="$2" kind="${3:-group}"
  local pattern candidate host negated matched=1
  while IFS= read -r pattern; do
    [ -n "$pattern" ] || continue
    negated=0
    case "$pattern" in
      !*) negated=1; pattern="${pattern#!}" ;;
    esac
    candidate="$pattern"
    if [ "$kind" = user ] && [[ "$pattern" = *@* ]]; then
      candidate="${pattern%@*}"
      host="${pattern##*@}"
      [[ "$name" = $candidate ]] || continue
      [ "$host" = '*' ] || return 2
    fi
    [[ "$name" = $candidate ]] || continue
    [ "$negated" -eq 0 ] || return 1
    matched=0
  done <<< "$patterns"
  return "$matched"
}

# verify_ssh_admission_controls <effective config file> <user>
#
# sshd -T exits successfully even when AllowUsers/DenyUsers or group controls
# reject the supplied user. Evaluate the reported lists after the final Docker
# group grant, before the working predecessor loses sudo and Docker access.
verify_ssh_admission_controls() {
  local src="$1" user="$2" effective patterns groups group rc allowed
  local deny_groups allow_groups
  if [ -n "$src" ]; then
    effective="$(cat "$src")" ||
      die "SSH admission controls could not be read for '$user'. The previous" \
	  "deploy user's privileged access will not be revoked."
  elif ! effective="$(sshd -T -C "user=$user" 2>/dev/null)"; then
    die "SSH admission controls could not be verified for '$user':" \
	"'sshd -T -C user=$user' failed. The previous deploy user's privileged" \
	"access will not be revoked. Run 'sshd -t', correct the configuration" \
	"and re-run."
  fi

  patterns="$(printf '%s\n' "$effective" |
    awk 'tolower($1) == "denyusers" { print $2 }')"
  if [ -n "$patterns" ]; then
    ssh_pattern_list_matches "$user" "$patterns" user
    rc=$?
    [ "$rc" -ne 0 ] ||
      die "SSH DenyUsers rejects '$user'. The previous deploy user's" \
	  "privileged access will not be revoked. Correct the admission rule" \
	  "and re-run."
    [ "$rc" -ne 2 ] ||
      die "SSH DenyUsers contains a host-scoped pattern for '$user' that a" \
	  "user-only verification cannot prove reachable. The previous deploy" \
	  "user's privileged access will not be revoked. Use an unconditional" \
	  "rule or remove the restriction, then re-run."
  fi

  patterns="$(printf '%s\n' "$effective" |
    awk 'tolower($1) == "allowusers" { print $2 }')"
  if [ -n "$patterns" ]; then
    ssh_pattern_list_matches "$user" "$patterns" user
    rc=$?
    [ "$rc" -eq 0 ] ||
      die "SSH AllowUsers does not unconditionally admit '$user'. The previous" \
	  "deploy user's privileged access will not be revoked. Add '$user' to" \
	  "the rule without an unverified host restriction and re-run."
  fi

  deny_groups="$(printf '%s\n' "$effective" |
    awk 'tolower($1) == "denygroups" { print $2 }')"
  allow_groups="$(printf '%s\n' "$effective" |
    awk 'tolower($1) == "allowgroups" { print $2 }')"
  [ -n "$deny_groups$allow_groups" ] || return 0

  groups="$(id -Gn "$user" 2>/dev/null)" ||
    die "SSH group admission could not be verified because the groups for" \
	"'$user' could not be read. The previous deploy user's privileged" \
	"access will not be revoked."

  if [ -n "$deny_groups" ]; then
    for group in $groups; do
      if ssh_pattern_list_matches "$group" "$deny_groups"; then
	die "SSH DenyGroups rejects '$user' through group '$group'. The previous" \
	    "deploy user's privileged access will not be revoked. Correct the" \
	    "admission rule and re-run."
      fi
    done
  fi

  if [ -n "$allow_groups" ]; then
    allowed=1
    for group in $groups; do
      ssh_pattern_list_matches "$group" "$allow_groups" && allowed=0
    done
    [ "$allowed" -eq 0 ] ||
      die "SSH AllowGroups admits none of '$user''s groups ($groups). The" \
	  "previous deploy user's privileged access will not be revoked. Add" \
	  "one of those groups to the rule and re-run."
  fi
}

verify_ssh_hardening() {
  local src="${1:-}" conf_dir="${2:-/etc/ssh}" reload_state="${3:-0}"
  local deploy_user="${4:-${APP_SSH_USER:-collavre}}"
  local require_readable="${5:-0}"
  local effective key value expected offender unsafe_match
  if [ -n "$src" ]; then
    effective="$(cat "$src")"
  else
    # A user-only connection context covers Match User, Match Group and
    # Match All, including group membership changes made later in this run.
    # It cannot answer for source/destination addresses, host names, listener
    # ports or routing domains: probing one invented connection would merely
    # leave every other connection untested. Refuse a weakening directive in
    # one of those contexts rather than report the privileged deploy account
    # hardened on incomplete evidence.
    unsafe_match="$(find_unsafe_ssh_match "$conf_dir")"
    [ -z "$unsafe_match" ] ||
      die "SSH hardening cannot be verified for every connection: a Match" \
	"Address/Host/LocalAddress/LocalPort/RDomain block changes" \
	"authentication, key lookup or admission at $unsafe_match." \
	"The user-only sshd test below cannot evaluate that context. Remove" \
	"or harden the directive and re-run before granting '$deploy_user'" \
	"sudo or Docker access."

    if ! effective="$(sshd -T -C "user=$deploy_user" 2>/dev/null)"; then
      [ "$require_readable" -ne 1 ] || die \
	"SSH public-key authentication could not be verified for '$deploy_user':" \
	"'sshd -T -C user=$deploy_user' rejected or could not read the" \
	"configuration on disk. The previous deploy user's privileged access" \
	"will not be revoked until the replacement account is proven reachable" \
	"by key. Run 'sshd -t' to find the error, fix it, and re-run."
      [ "$reload_state" -ne 2 ] || die \
	"SSH hardening could not be verified: there is no active sshd to reload" \
	"and 'sshd -T -C user=$deploy_user' rejected or could not read the" \
	"configuration on disk." \
	"The next socket-activated connection or reboot would start sshd from" \
	"that unverified configuration. Provisioning will not continue. Run" \
	"'sshd -t' to find the error, fix it, and re-run."
      log "WARNING: could not read the effective SSH configuration on this host" \
	"(\`sshd -T -C user=$deploy_user\` failed), so the hardening above is" \
	"unverified. Check it by hand: sshd -T -C user=$deploy_user | grep -E" \
	"'^(passwordauthentication|permitrootlogin|kbdinteractiveauthentication|" \
	"pubkeyauthentication)'"
      return 0
    fi
  fi
  for key in passwordauthentication permitrootlogin kbdinteractiveauthentication \
	     pubkeyauthentication; do
    expected=no
    [ "$key" != pubkeyauthentication ] || expected=yes
    value="$(printf '%s\n' "$effective" |
             awk -v k="$key" 'tolower($1) == k { print $2; exit }')"
    [ -n "$value" ] || {
      [ "$key" != pubkeyauthentication ] || die \
	"SSH public-key authentication could not be verified for '$deploy_user':" \
	"sshd did not report 'pubkeyauthentication'. The previous deploy user's" \
	"privileged access will not be revoked until the replacement account is" \
	"proven reachable by key. Correct the SSH configuration and re-run."
      log "WARNING: sshd did not report '$key', so that part of the hardening" \
          "above is unverified"
      continue
    }
    if [ "$value" = "$expected" ]; then
      continue
    fi
    # Name the file rather than leave the operator to find it. A directive
    # above the Include, an earlier drop-in or a matching Match block can get
    # here, and all three are one grep away.
    offender="$(grep -ilE "^[[:space:]]*$key[[:space:]]" \
                  "$conf_dir"/sshd_config.d/*.conf "$conf_dir"/sshd_config \
                  2>/dev/null | grep -v '01-collavre.conf' | head -1)" || true
    die "SSH hardening did not take effect: sshd resolves '$key' to '$value'," \
	"not '$expected', even though $conf_dir/sshd_config.d/01-collavre.conf sets" \
	"it. An earlier global directive or a Match block for '$deploy_user'" \
	"is overriding it${offender:+ — ${offender}}. Stopping before any" \
	"further access is granted. Remove or correct that setting and re-run."
  done
}

# --------------------------------------------------------------------------
log "3/9 SSH hardening + deploy user '$APP_SSH_USER'"
# --------------------------------------------------------------------------
install -d -m 0755 /etc/ssh/sshd_config.d
# 01-, not 99-. sshd_config(5): "for each keyword, the first obtained value will
# be used", and the Include glob is expanded in lexical order — so a drop-in
# that sorts *after* an existing one cannot override it, which is the opposite
# of how a "99-" suffix reads. Ubuntu's cloud images ship 50-cloud-init.conf,
# and on an existing instance it commonly carries `PasswordAuthentication yes`.
# Measured with `sshd -T`, on OpenSSH 9.x/Linux and 10.2/macOS alike:
#
#   drop-ins present                        passwordauth  permitrootlogin
#   50-cloud-init.conf + 99-collavre.conf   yes           yes
#   50-cloud-init.conf + 01-collavre.conf   no            no
#   01-collavre.conf alone (fresh host)     no            no
#
# `kbdinteractiveauthentication no` in every row is the control: the 99- file
# was being read the whole time. It lost only the keywords something else had
# already set — which is every keyword that matters here, on exactly the hosts
# the existing-instance path exists for.
#
# The drop-in below, and the sysctl one in step 2, go through
# install_managed_config rather than a `cat >` heredoc, for the reason the
# daemon.json rewrite and the managed-block append do: `>` truncates before it
# writes, and a run killed between the two — an OOM kill or an ENOSPC on a
# 512MB instance — leaves the live drop-in short. Measured against a real sshd,
# with Ubuntu's 50-cloud-init.conf beside it turning both keywords back on:
#
#   01-collavre.conf state   bytes   sshd -t   passwordauth  permitrootlogin
#   whole                   102      rc=0      no            no
#   0 bytes (torn at open)    0      rc=0      yes           yes
#   cut after line 1         26      rc=0      no            yes
#   cut mid-directive        36      rc=255    -             -
#   cut mid-value            43      rc=255    -             -
#
# Two bands, and only one of them is loud. The bottom rows stop sshd from
# starting, which locks the host out at its next boot. The middle two are the
# quiet ones: sshd reads them happily and the hardening is silently reduced or
# gone entirely, on a host whose provisioning was killed rather than one that
# reported success — so nothing ever says so.
#
# `sshd -t` is what the finding asks for and it cannot close the quiet band: it
# answers rc=0 for the empty file, which is the state truncate-at-open leaves.
# That is the same fact the `jq empty` fix two functions over rests on — a
# validator that asks "is this a configuration" cannot tell a zero-length one
# from a correct one. So the staged file is asked whether it *says* what it was
# staged to say, and only then renamed.
#
# verify_ssh_hardening below is not a substitute for this and does not overlap
# it. It reads back sshd's resolution on a run that got that far; the exposure
# here is a run that did not, and for that the only answer is that the live file
# was never opened for writing.
install_managed_config 'the SSH hardening drop-in' \
  /etc/ssh/sshd_config.d/01-collavre.conf \
  'PasswordAuthentication no' \
  'PermitRootLogin no' \
  'KbdInteractiveAuthentication no' \
  'PubkeyAuthentication yes'
# A host provisioned by an earlier version of this script carries the 99- file.
# It is inert now that 01- sets the same keywords first, and that is the reason
# to remove it rather than leave it: a file whose every line is overridden is
# one an operator can edit to no effect.
rm -f /etc/ssh/sshd_config.d/99-collavre.conf
# Ubuntu ships `Include /etc/ssh/sshd_config.d/*.conf` at the top of
# sshd_config; without it the drop-in above is silently ignored.
grep -q '^Include /etc/ssh/sshd_config.d/' /etc/ssh/sshd_config 2>/dev/null || \
  log "WARNING: sshd_config has no Include for sshd_config.d — harden SSH by hand"
# reload_ssh_daemon — reload whichever unit carries sshd.
#
# Returns 0 when a unit adopted the configuration, 1 when a running daemon
# refused it, and 2 when neither unit is active and there was nothing to reload.
#
# `|| true` here used to swallow the status, and the status means two different
# things. Measured under systemd 252, one unit state per row, with ExecReload
# standing in for sshd's own accept-or-refuse:
#
#   unit state              reload rc   is-active   what it means
#   inactive                1           inactive    nothing to reload
#   not found at all        5           inactive    nothing to reload
#   active, reload ok       0           active      adopted
#   active, reload refused  1           active      still on the OLD config
#
# rc alone cannot separate rows 1 and 4 — both are 1 — and rc 1 on row 1 is the
# stock state this runbook targets, not an edge case: Ubuntu 24.04's
# openssh-server enables ssh.socket and leaves ssh.service disabled, so until
# something connects both `reload ssh` and `reload sshd` fail on a host that is
# entirely healthy. The next connection starts sshd fresh and the drop-in is
# already in force. Dying on rc alone would refuse every correctly-provisioned
# instance — the same over-refusal refuse_nologin_deploy_user and the
# pg_lsclusters guard each had to be shaped around, and worse than the defect
# because it fires on every invocation.
#
# So the discriminator is whether the unit was active, which is exactly the
# question "was there a daemon to refuse this". Read from systemctl rather than
# from the rc or the message: rc 1 is overloaded and the message is localised.
reload_ssh_daemon() {
  local unit
  for unit in ssh sshd; do
    systemctl reload "$unit" >/dev/null 2>&1 && return 0
    [ "$(systemctl is-active "$unit" 2>/dev/null)" = active ] && return 1
  done
  return 2
}
# Fatal, and *before* verify_ssh_hardening rather than folded into it, because
# on this path that function is answering the wrong question. `sshd -T` re-reads
# the files on disk; it cannot report what the daemon currently in memory is
# using. So on a refused reload it confirms the hardening from the very file the
# daemon just rejected, and the run proceeds to grant docker, passwordless sudo
# and keys while the live daemon is still on whatever PasswordAuthentication it
# had. Nothing on the host says so.
#
# And the disk state is its own outage in waiting: the configuration sshd
# refused is the one it will be handed at the next boot, where there is no old
# process to keep running.
#
# Stopping here is the safe end. This first check is at the top of step 3 — the
# deploy account does not exist yet, nothing has been granted, and SSH is left
# exactly as the operator had it, so the refusal locks nobody out. The same
# verifier runs again immediately after later group changes, when its answer can
# differ because Match Group has begun to apply.
SSH_RELOAD_STATE=0
reload_ssh_daemon || SSH_RELOAD_STATE=$?
[ "$SSH_RELOAD_STATE" -ne 1 ] || die \
  "SSH hardening was written but the running sshd refused to reload it." \
  "The live daemon is still using the configuration it started with, so the" \
  "hardening above is NOT in effect — and sshd will be handed the same" \
  "rejected configuration at the next boot, where no old process survives to" \
  "keep the host reachable. Nothing has been granted and SSH is unchanged." \
  "Find the offending directive with 'sshd -t', fix it, and re-run."
verify_ssh_hardening "" /etc/ssh "$SSH_RELOAD_STATE" "$APP_SSH_USER"

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
# Every account whose authorized_keys contains this key byte-for-byte, one per
# line, or nothing. This is the only surviving evidence of which accounts a
# legacy host-wide marker belongs to, which the caller below needs and does not
# otherwise have.
ssh_key_holder() {
  local key="$1" src="${2:-}" user home tbl rc=1 grep_rc
  tbl="$(mktemp)" || return 2
  if [ -n "$src" ]; then
    if ! cat "$src" > "$tbl"; then rm -f "$tbl"; return 2; fi
  else
    if ! getent passwd > "$tbl"; then rm -f "$tbl"; return 2; fi
  fi
  while IFS=: read -r user _ _ _ _ home _; do
    [ -n "$home" ] && [ -f "$home/.ssh/authorized_keys" ] || continue
    if grep -qxF "$key" "$home/.ssh/authorized_keys" 2>/dev/null; then
      printf '%s\n' "$user"
      rc=0
    else
      grep_rc=$?
      [ "$grep_rc" -eq 1 ] || { rm -f "$tbl"; return 2; }
    fi
  done < "$tbl"
  rm -f "$tbl"
  return "$rc"
}

# record_ssh_key_grant <key> [set file] [legacy single marker]
#
# The third instance of the same separation, after deploy_users and db_users:
# ssh_public_key.<user> is the key this host is *currently* deployed with, and
# this file is the set of managed keys no run has confirmed withdrawn. One
# marker cannot be both, and the A -> B -> C sequence is where it shows.
#
# install_authorized_keys appends the successor and revoke_prior_ssh_key
# advances the marker afterwards, so a run that dies between them leaves B in
# authorized_keys with the marker still naming A. A later run rotating to C
# withdraws A — the only key the marker knows — records C, and B stays
# authorized with nothing on the host naming it. Measured against 07365195:
#
#   control  A -> B -> C                       keys=[C]    marker=C
#   run2 interrupted before the marker write:
#            A -> B(interrupted) -> C          keys=[B C]  marker=C
#
# B is not a stale entry in a file: this account holds passwordless sudo and the
# docker socket, so an untracked key on it is permanent root on the host, and it
# is untracked precisely because the rotation that was supposed to retire it is
# the thing that lost the record.
#
# Called before the key is appended, not after — the same ordering as
# record_deploy_user_grant, and for the same reason: a key in this file that
# turns out not to be in authorized_keys costs one grep, and a key missing from
# it is root access nobody is looking for.
record_ssh_key_grant() {
  local key="$1" set_file="${2:-$STATE_DIR/ssh_public_keys.$APP_SSH_USER}"
  local prior_file="${3:-$STATE_DIR/ssh_public_key.$APP_SSH_USER}"
  [ -n "$key" ] || return 0
  # Upgrade path, guarded on `! -f` so it runs once per host: seed from the
  # single marker the earlier revision kept, which names the predecessor most
  # likely to still be authorized. A failed seed leaves the file absent — the
  # state a retry starts from — rather than empty and authoritative.
  if [ ! -f "$set_file" ] && [ -s "$prior_file" ]; then
    local seed
    seed="$(grep -v '^[[:space:]]*$' "$prior_file")" || seed=''
    if [ -n "$seed" ]; then
      write_state_file "$set_file" "$seed"$'\n' || return 1
    fi
  fi
  append_state_line "$set_file" "$key"
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
  local legacy key owners owner first_owner home auth_keys="" set_file marker
  local holder_status=0
  legacy="$state_dir/ssh_public_key"
  [ -f "$legacy" ] || return 0

  key="$(cat "$legacy")"
  # A marker with nothing in it names no key and can strand the branch forever.
  [ -n "$key" ] || { rm -f "$legacy"; return 0; }

  home="$(passwd_home "$user" "$src")"
  [ -z "$home" ] || auth_keys="$home/.ssh/authorized_keys"

  owners="$(ssh_key_holder "$key" "$src")" || holder_status=$?
  if [ "$holder_status" -gt 1 ]; then
    die "could not inspect every account for the SSH key recorded in $legacy." \
	"The host-wide marker is intact and no key was re-filed. Check that the" \
	"account database and authorized_keys files are readable, then re-run."
  fi
  [ "$holder_status" -eq 0 ] || owners=""

  # Authorized for nobody: the key it names is already gone, so the record
  # describes nothing and assigning it to an account would invent a predecessor
  # that no longer exists.
  if [ -z "$owners" ]; then
    rm -f "$legacy"
    log "the SSH key recorded by an earlier revision is no longer authorized for" \
        "any account on this host, so the record was dropped rather than filed" \
        "against '$user'"
    return 0
  fi

  # If this account does not hold the recorded key but does hold other keys, an
  # earlier rotation may have installed one of them and then advanced the sole
  # host-wide marker to another account. Nothing can identify that predecessor,
  # so stop before recording or granting anything unless the operator accepts
  # responsibility for those unattributed keys.
  if ! grep -qxF -- "$user" <<<"$owners" &&
     [ -n "$auth_keys" ] && [ -s "$auth_keys" ] &&
     [ -z "${ACK_UNATTRIBUTED_SSH_KEYS:-}" ]; then
    first_owner="${owners%%$'\n'*}"
    die "this host rotated deploy accounts under an earlier revision of this" \
	"script: the key it recorded is authorized for '$first_owner', not for" \
	"'$user', which this run names. That revision kept only one record per" \
	"host, so if it ever installed a key for '$user' there is nothing left" \
	"that says which of the keys in $auth_keys it was — and this run is" \
	"about to give '$user' passwordless sudo and the docker socket again." \
	"Nothing has been changed. Read $auth_keys, remove any key you do not" \
	"recognise, then re-run with ACK_UNATTRIBUTED_SSH_KEYS=1 to continue."
  fi

  # The old marker was host-wide, so the same managed key may have been copied
  # into more than one deploy account. Queue it for every exact holder before
  # deleting the sole record; otherwise whichever account was not chosen can be
  # re-armed by a later APP_SSH_USER rotation with an untracked root key.
  while IFS= read -r owner; do
    [ -n "$owner" ] || continue
    set_file="$state_dir/ssh_public_keys.$owner"
    marker="$state_dir/ssh_public_key.$owner"
    record_ssh_key_grant "$key" "$set_file" "$marker" ||
      die "could not record the legacy SSH key for '$owner' in $set_file." \
	  "The host-wide marker is intact; check that $state_dir is writable" \
	  "and has space, then re-run."
    if [ ! -f "$marker" ]; then
      write_state_file "$marker" "$key"$'\n' ||
	die "could not create the per-account SSH key marker $marker." \
	    "The withdrawal queue and host-wide marker are intact; check that" \
	    "$state_dir is writable and has space, then re-run."
    fi
  done <<<"$owners"
  rm -f "$legacy"

  if ! grep -qxF -- "$user" <<<"$owners"; then
    first_owner="${owners%%$'\n'*}"
    if [ -n "${ACK_UNATTRIBUTED_SSH_KEYS:-}" ]; then
      log "ACK_UNATTRIBUTED_SSH_KEYS is set: filed the earlier revision's record" \
	  "against every account that holds it, including '$first_owner', and" \
	  "proceeding with '$user' unchecked — the keys in $auth_keys are the" \
	  "operator's responsibility"
    else
      log "the SSH key recorded by an earlier revision belongs to" \
	  "'$first_owner', not to '$user'; filed it against every account that" \
	  "holds it"
    fi
  fi
}

adopt_legacy_ssh_key_marker "$APP_SSH_USER"

if ! id -u "$APP_SSH_USER" >/dev/null 2>&1; then
  adduser --disabled-password --gecos "Collavre deploy" "$APP_SSH_USER"
fi
APP_HOME="$(getent passwd "$APP_SSH_USER" | cut -d: -f6)"
AUTH_KEYS="$APP_HOME/.ssh/authorized_keys"
# The file this script writes must be one sshd actually reads for this account.
# Check after account creation (so %h/%u/%U can resolve) but before recording or
# granting sudo. A custom AuthorizedKeysFile is supported only when it expands
# to the same target; otherwise leave the host's access model untouched.
verify_ssh_key_destination "" "$APP_SSH_USER" "$APP_HOME" "$AUTH_KEYS"
# Before the grant, not after it. Everything from here to the revocation at the
# end of step 4 — the whole Docker install — is a window in which an interrupted
# run would otherwise leave this account holding sudo and docker with nothing on
# the host recording that it does, and no later run able to find it.
record_deploy_user_grant "$APP_SSH_USER" ||
  die "could not record '$APP_SSH_USER' in $STATE_DIR/deploy_users, so this run" \
      "cannot promise that a later one could find the account again. Nothing" \
      "has been granted. Check that $STATE_DIR is writable and has space, then" \
      "re-run."
SUDO_GROUP_WAS_PRESENT=0
in_group "$APP_SSH_USER" sudo && SUDO_GROUP_WAS_PRESENT=1
usermod -aG sudo "$APP_SSH_USER"
# Match Group is resolved from the account's current memberships, so the check
# before user creation cannot see an override that starts applying here.
if ! (
  verify_ssh_hardening "" /etc/ssh "$SSH_RELOAD_STATE" "$APP_SSH_USER" 1 &&
  verify_ssh_key_destination "" "$APP_SSH_USER" "$APP_HOME" "$AUTH_KEYS"
); then
  if [ "$SUDO_GROUP_WAS_PRESENT" -eq 0 ]; then
    gpasswd -d "$APP_SSH_USER" sudo >/dev/null 2>&1 ||
      die "SSH hardening failed after '$APP_SSH_USER' joined sudo, and the" \
	"new membership could not be rolled back. Remove it immediately with" \
	"'gpasswd -d $APP_SSH_USER sudo'."
    in_group "$APP_SSH_USER" sudo &&
      die "SSH hardening failed after '$APP_SSH_USER' joined sudo. The rollback" \
	"reported success but the membership is still active; remove it" \
	"immediately with 'gpasswd -d $APP_SSH_USER sudo'."
    log "rolled back the new sudo membership after SSH hardening verification failed"
  fi
  die "SSH hardening failed after the sudo group change. Any membership added" \
    "by this run was rolled back; correct the Match override and re-run."
fi
install -d -m 0755 /etc/sudoers.d
ensure_sudoers "$APP_SSH_USER"

APP_SSH_GROUP="$(install_deploy_ssh_dir "$APP_SSH_USER" "$APP_HOME")"
touch "$AUTH_KEYS"

# stage_authorized_keys <authorized_keys> — echo the path of a staging file
# holding the current contents of <authorized_keys>, newline-terminated.
#
# The counterpart of append_state_line for the one file that is not a queue but
# the way into the host. `>> authorized_keys` leaves an unterminated fragment
# when the write is cut short, and the *retry* is what does the damage: the
# `grep -qxF` guarding the append does not match a fragment, so the whole key
# lands on the end of it and authorized_keys holds one line that is neither key.
#
# That is worse here than in a queue, because revoke_prior_ssh_key opens with
# `grep -qxF "$SSH_PUBLIC_KEY" "$auth_keys" || return 0` — never withdraw before
# the successor is in place. With the successor glued to a fragment that check
# fails, so the run withdraws nothing, reports a completed rotation, and leaves
# the predecessor authorized on an account holding docker and passwordless sudo.
# Measured on the extracted pair, the append torn on the rotation to B:
#
#   run 3 (retry)      line 2: <fragment of B><whole of B>
#                      exact line for B: no    A still authorized: YES
#   run 4 (converge)   exact line for B: YES   A still authorized: no
#
# So the exposure is bounded — the next convergence appends B cleanly and the
# withdrawal catches up — but it is a full run long, and the run that opens it
# is the one that prints the success summary. A rotation performed *because* the
# predecessor is compromised is exactly the case where one more run matters.
#
# Terminating rather than dropping the fragment, for the same reason as
# append_state_line: nothing distinguishes half a key from a different key, and
# a key an operator added by hand must survive this untouched. A fragment
# authorizes nobody, and dedupe_authorized_keys is what eventually clears it.
stage_authorized_keys() {
  local auth_keys="$1" tmp
  tmp="$(mktemp "$auth_keys.stage.XXXXXX")" || return 1
  if [ -s "$auth_keys" ]; then
    cat "$auth_keys" > "$tmp" || { rm -f "$tmp"; return 1; }
    # Command substitution strips trailing newlines, so this is empty exactly
    # when the file already ends in one.
    [ -z "$(tail -c 1 "$tmp")" ] || printf '\n' >> "$tmp"
  fi
  printf '%s\n' "$tmp"
}

# install_authorized_keys <authorized_keys> [home root]
#
# Give the deploy user a way in: the explicit SSH_PUBLIC_KEY when there is one,
# otherwise whatever key Lightsail installed for the default cloud user.
#
# Non-zero when the key could not be installed, which aborts the run at the call
# site: the steps after it put this account in docker and sudoers, and an
# account granted root-equivalent access with no working key is a host nobody
# can reach with a summary that says otherwise.
install_authorized_keys() {
  local auth_keys="$1" home_root="${2:-/home}" candidate src tmp
  if [ -n "$SSH_PUBLIC_KEY" ]; then
    grep -qxF "$SSH_PUBLIC_KEY" "$auth_keys" 2>/dev/null && return 0
    tmp="$(stage_authorized_keys "$auth_keys")" || return 1
    printf '%s\n' "$SSH_PUBLIC_KEY" >> "$tmp" || { rm -f "$tmp"; return 1; }
    # Never install a file that does not contain the key it was staged to add,
    # and never one shorter than what it replaces. The staging write can fail
    # for space just as the live one could; the difference is that here the
    # failure is discardable.
    local was=0
    [ -f "$auth_keys" ] && was="$(wc -l < "$auth_keys")"
    if ! grep -qxF "$SSH_PUBLIC_KEY" "$tmp" || [ "$(wc -l < "$tmp")" -le "$was" ]; then
      rm -f "$tmp"
      log "WARNING: a staged $auth_keys did not come out whole, so it was NOT" \
          "installed and the live file is untouched"
      return 1
    fi
    install_staged_authorized_keys "$tmp" "$auth_keys" || return 1
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
      # Same staging as the explicit-key path. This copy is larger — a cloud
      # user's authorized_keys, not one line — so it is the one more likely to
      # be cut short, and it lands on the file the operator is logged in with.
      tmp="$(stage_authorized_keys "$auth_keys")" || return 1
      cat "$src" >> "$tmp" || { rm -f "$tmp"; return 1; }
      # Record what was copied, or the rotation this documents cannot undo it.
      # `record_ssh_key_grant "$SSH_PUBLIC_KEY"` at the call site is a no-op on
      # this path — the variable is empty, that is what put us here — so the
      # queue stayed empty and a later run naming an explicit key found no
      # predecessor to withdraw. Measured on the shipped functions, the two runs
      # the runbook describes:
      #
      #   run 1  SSH_PUBLIC_KEY=''      authorized: cloud-1 cloud-2   queue: -
      #   run 2  SSH_PUBLIC_KEY=<new>   authorized: cloud-1 cloud-2 new
      #                                 queue: new
      #
      # The table in docs says changing SSH_PUBLIC_KEY on a re-run "withdraws
      # the key it replaces", and on the empty -> explicit transition it
      # withdrew nothing, on the account that has passwordless sudo and docker.
      #
      # Only on this branch, never on the `-ef` one above: there the file *is*
      # the cloud user's own, so queueing it would have a later rotation strip
      # the operator's Lightsail key from the account they log in as. Copied
      # keys are this script's to withdraw; a cloud account's own keys are not.
      #
      # Before the install, and fatal rather than warned. Recording afterwards
      # cannot be made safe: by then the keys are authorized on an account this
      # run is about to give docker and passwordless sudo, and a failed record
      # leaves them there untracked with only a log line. Measured on the
      # shipped functions with the state directory unwritable, which is what a
      # full disk on a 512MB instance looks like from here:
      #
      #   record        run 1 rc   queued   authorized after the rotation
      #   succeeds      0          2        new
      #   fails         0          0        cloud-1 cloud-2 new
      #
      # The second row is the defect the fix above was written for, reached
      # through its failure path — an rc of 0, a summary that reports a
      # converged host, and two keys the documented rotation will never
      # withdraw.
      #
      # Ordered this way the two failures are not symmetric, which is why this
      # order and not the other. Recorded-but-not-installed is harmless: the
      # revoke loop skips a queued key that is absent from authorized_keys, and
      # append_state_line dedupes, so the retry after the disk is freed records
      # nothing twice. Installed-but-not-recorded is the finding.
      #
      # Aborting is the safe end here rather than a lesser one, though not
      # because the host is untouched — checked against the call order rather
      # than assumed, and only half of it is true:
      #
      #   usermod -aG sudo / ensure_sudoers   step 3, BEFORE this
      #   install_authorized_keys             <- here
      #   usermod -aG docker                  step 6, after
      #
      # So the account already holds passwordless sudo when this returns
      # non-zero. What makes that the safe end anyway is that nothing was
      # installed: an account with sudo and an empty authorized_keys cannot be
      # logged into at all, and the docker grant is never reached. That is
      # exactly the state the `die` at the call site already names, down to
      # telling the operator the grant is recorded in $STATE_DIR/deploy_users
      # so a later run takes it back. The operator still reaches the host as
      # the cloud user, whose own keys this script never writes.
      # Guarded on the two state variables the same way install_staged_authorized_keys
      # guards its chown on APP_SSH_USER: this function is called directly by a
      # dozen fixtures that have no state directory and no deploy account, and
      # under `set -u` naming them unconditionally makes it abort there. The
      # real call site always has both — it is the line below that sets
      # AUTH_KEYS — so the production path is the one that records.
      if [ -n "${STATE_DIR:-}" ] && [ -n "${APP_SSH_USER:-}" ]; then
	while IFS= read -r _copied; do
          case "$_copied" in ''|'#'*) continue ;; esac
          record_ssh_key_grant "$_copied" || {
            rm -f "$tmp"
            log "could not record a key copied from $candidate in" \
                "$STATE_DIR, so a later SSH_PUBLIC_KEY rotation would leave it" \
                "authorized on '$APP_SSH_USER' for good: ${_copied##* }." \
                "Nothing was installed and $auth_keys is untouched — is" \
                "$STATE_DIR writable, and does the instance have disk left?"
            return 1
          }
        done < "$src"
      fi
      install_staged_authorized_keys "$tmp" "$auth_keys" || return 1
    fi
    return 0
  done

  # No SSH_PUBLIC_KEY and no cloud user to copy from. A `for` loop whose every
  # iteration took the `continue` completes with status 0, so that used to be
  # this function's answer — the contract above says non-zero aborts the run,
  # and the one path where nothing could be installed was the one reporting
  # success.
  #
  # Not unconditionally, though: an account that already has a key is not a
  # failure to give it one. A host whose cloud user was renamed or removed
  # converges through here on every later run with authorized_keys already
  # populated, and refusing that would take down every re-run on a host that is
  # working — a worse defect than the one being fixed, and one no negative
  # control catches, since a control only exercises the empty file.
  if [ -s "$auth_keys" ]; then
    log "no SSH_PUBLIC_KEY given and no cloud user's keys to copy —" \
        "$auth_keys already authorizes someone, so it is left as it is"
    return 0
  fi
  return 1
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
#
# Which is why a chown that fails refuses the install rather than being
# suppressed. Suppressing it puts the root-owned 0600 file at the live path,
# and the caller's own `chown "$APP_SSH_USER:$APP_SSH_GROUP" "$AUTH_KEYS"` a few
# lines later is not a recovery: it is the same command on the same names, so it
# fails for whatever reason this one just did and `set -e` ends the run with the
# unreadable file already installed. Declining to install leaves the live file
# as it was — still holding a key that works — so the cost is a run rather than
# the host, and on APP_SSH_USER=ubuntu the host is the only way in.
install_staged_authorized_keys() {
  local tmp="$1" auth_keys="$2"
  if [ -n "${APP_SSH_USER:-}" ] &&
     ! chown "$APP_SSH_USER:${APP_SSH_GROUP:-$APP_SSH_USER}" "$tmp" 2>/dev/null; then
    rm -f "$tmp"
    log "WARNING: could not give a rewritten $auth_keys to" \
        "'$APP_SSH_USER' — sshd refuses an authorized_keys it cannot read as" \
        "the user, so it was NOT installed and the live file is untouched"
    return 1
  fi
  chmod 0600 "$tmp"
  mv -f "$tmp" "$auth_keys"
}

revoke_prior_ssh_key() {
  local auth_keys="$1" state="${2:-$STATE_DIR/ssh_public_key.$APP_SSH_USER}"
  # Derived from $state, not rebuilt from $APP_SSH_USER: a caller that passes
  # an explicit marker path — every case in the suite that predates the queue —
  # need not also have $APP_SSH_USER set, and the two names cannot drift onto
  # different accounts. 'ssh_public_key.deploy' -> 'ssh_public_keys.deploy'.
  local base="${state##*/}"
  local set_file="${3:-${state%/*}/ssh_public_keys${base#ssh_public_key}}"
  local prior tmp pat kept='' drop='' n=0
  # An empty SSH_PUBLIC_KEY means "keep using the cloud user's keys", not
  # "retire the managed one" — withdrawing here would strand an operator who
  # simply dropped the variable from a re-run.
  [ -n "$SSH_PUBLIC_KEY" ] || return 0
  # Never revoke before the successor is actually in place: an interrupted run
  # must leave two usable keys, never zero.
  grep -qxF "$SSH_PUBLIC_KEY" "$auth_keys" || return 0

  # Seeds the set on a host the earlier revision provisioned, and puts the
  # current key in it on a first run, so a later rotation has a predecessor to
  # withdraw. The call site records it earlier too, before the append; this one
  # is what makes the function correct when called on its own.
  record_ssh_key_grant "$SSH_PUBLIC_KEY" "$set_file" "$state" || {
    log "WARNING: could not record the current SSH key in '$set_file'; no key" \
        "was withdrawn on this run, and the queue is unchanged"
    return 0
  }

  while IFS= read -r prior; do
    [ -n "$prior" ] || continue
    # The key this run deploys with stays: it is what the *next* rotation
    # withdraws.
    if [ "$prior" = "$SSH_PUBLIC_KEY" ]; then
      kept="$kept$prior"$'\n'
      continue
    fi
    # Already absent from authorized_keys — withdrawn by an earlier run, or by
    # the operator. Nothing outstanding, so it leaves the queue.
    grep -qxF "$prior" "$auth_keys" || continue
    drop="$drop$prior"$'\n'
    n=$((n + 1))
  done < "$set_file"

  if [ -n "$drop" ]; then
    # One rewrite for the whole queue rather than one per key: each rewrite is
    # a chance to install a short file, and authorized_keys is the only way
    # into this host.
    #
    # Staged beside the target rather than in $TMPDIR: same filesystem, so
    # the rewrite below cannot fail for space the staging just proved is
    # there, and a small or full /tmp is not on its own able to break the
    # file the operator logs in with.
    pat="$(mktemp "$auth_keys.revoke.XXXXXX")"
    printf '%s' "$drop" > "$pat"
    tmp="$(mktemp "$auth_keys.revoke.XXXXXX")"
    # Exact whole-line matches: a key is withdrawn only if it is byte-for-byte
    # one of those recorded, so an operator key that merely shares a comment or
    # a prefix survives.
    grep -vxF -f "$pat" "$auth_keys" > "$tmp" || true
    rm -f "$pat"
    # Check what the staged file *is*, not merely that it exists. `grep`
    # writing a short file is the dangerous case and it is the likely one:
    # the successor was appended, so it is the last line, and a write that
    # runs out of space stops before reaching it. A size test passes on
    # that file, the install goes ahead, and the account is locked out of a
    # host whose log says the rotation succeeded. The `|| true` above —
    # needed so `set -e` does not fire on grep's "no lines selected" — is
    # what hides the error, so the successor's presence has to be
    # re-established here. The install is part of the condition rather than a
    # statement after it: it declines to install a file it could not give to
    # the user, and a withdrawal that did not reach the live file has
    # withdrawn nothing.
    if grep -qxF "$SSH_PUBLIC_KEY" "$tmp" &&
       install_staged_authorized_keys "$tmp" "$auth_keys"; then
      log "withdrew $n SSH key(s) this script installed on previous runs"
    else
      rm -f "$tmp"
      log "WARNING: could not withdraw $n previous SSH key(s) — is the disk full?" \
          "They are still authorized; remove them by hand once the host is healthy"
      # Deliberately kept in the queue, so the next run retries the withdrawal
      # instead of forgetting keys that still hold root on this account.
      kept="$kept$drop"
    fi
  fi

  write_state_file "$set_file" "$kept" ||
    log "WARNING: could not rewrite '$set_file'. Any key withdrawn above is" \
        "still withdrawn; this host merely still lists it, and a later run" \
        "will find it absent from $auth_keys and drop it then."

  # The single marker stays the record of the key this host is deployed with —
  # adopt_legacy_ssh_key_marker keys off its presence — while the set above is
  # the queue. Written atomically: a bare redirection truncates at open, and an
  # empty marker here reads as "no managed key" to the adoption path.
  write_state_file "$state" "$SSH_PUBLIC_KEY"$'\n' ||
    log "WARNING: could not record the current SSH key in '$state'"
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
     { [ -z "$must_keep" ] || grep -qxF "$must_keep" "$tmp"; } &&
     install_staged_authorized_keys "$tmp" "$auth_keys"; then
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
# Before the append, not after. install_authorized_keys puts the key in
# authorized_keys on an account that already holds sudo and docker; an
# interrupted run between that and the record below would otherwise leave a
# root-equivalent key no later run can find.
record_ssh_key_grant "$SSH_PUBLIC_KEY" ||
  die "could not record the SSH key in $STATE_DIR/ssh_public_keys.$APP_SSH_USER," \
      "so this run cannot promise that a later one could find the key again." \
      "Nothing has been installed. Check that $STATE_DIR is writable and has" \
      "space, then re-run."
# The status is acted on rather than left to errexit. A bare call does abort
# under `set -euo pipefail`, but it aborts with nothing said — and the one thing
# this failure needs to say is which account was left holding sudo, since the
# operator's next move is either to supply a key or to take that grant back.
install_authorized_keys "$AUTH_KEYS" ||
  die "no SSH key could be installed for '$APP_SSH_USER': SSH_PUBLIC_KEY is" \
      "empty, none of /home/{ubuntu,admin,ec2-user}/.ssh/authorized_keys" \
      "exists, and $AUTH_KEYS is empty. Stopping here rather than finishing:" \
      "'$APP_SSH_USER' already has passwordless sudo from the step above, and" \
      "a run that carried on would print KAMAL_SSH_USER=$APP_SSH_USER over an" \
      "account nothing can log in as. The grant is recorded in" \
      "$STATE_DIR/deploy_users, so a later run naming a different APP_SSH_USER" \
      "takes it back. Re-run with" \
      "SSH_PUBLIC_KEY=\"\$(cat ~/.ssh/id_ed25519.pub)\"."
# Previous managed keys stay authorized until the staged key has opened a real
# SSH session and the nonce is finalized. Removing them here would merely move
# the lockout decision from sshd configuration analysis to another unproved
# assumption.
dedupe_authorized_keys "$AUTH_KEYS" "$SSH_PUBLIC_KEY"
chown "$APP_SSH_USER:$APP_SSH_GROUP" "$AUTH_KEYS"
chmod 0600 "$AUTH_KEYS"
# Still a warning rather than a second gate, and what it covers has narrowed to
# the *other* way this file ends up empty: a withdrawal or a dedupe that removed
# the last line, where a key was installed and stopping would be wrong. The
# no-key-at-all case is the `die` above, which is the one that has to stop.
[ -s "$AUTH_KEYS" ] || log "WARNING: $AUTH_KEYS is empty — kamal will not be able to connect"

# --------------------------------------------------------------------------
log "4/9 Docker CE"
# --------------------------------------------------------------------------
# What to install, decided per package rather than from the presence of the
# `docker` binary. The plugin install used to sit inside `if ! command -v
# docker`, which made it unreachable on the one host that needs it named
# separately: a by-hand run on an existing instance — the documented path — that
# already carries Ubuntu's `docker.io`. There `command -v docker` answers, the
# whole branch is skipped, and neither buildx nor compose is ever installed,
# while docs/deploy_to_lightsail.md tells the operator the launch script
# installs buildx so the remote builder works out of the box. The first
# `builder.remote` Kamal build then fails on a host this script reported as
# converged.
#
# `docker buildx version` rather than a test on a path: the CLI looks for
# plugins in several directories, and what decides whether Kamal can build is
# whether the CLI finds one, not whether a particular file is there.
DOCKER_WANT=''
if ! command -v docker >/dev/null 2>&1; then
  DOCKER_WANT='docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin'
else
  docker buildx version  >/dev/null 2>&1 || DOCKER_WANT="$DOCKER_WANT docker-buildx-plugin"
  docker compose version >/dev/null 2>&1 || DOCKER_WANT="$DOCKER_WANT docker-compose-plugin"
  [ -z "$DOCKER_WANT" ] ||
    log "docker is already installed but$DOCKER_WANT is missing — installing it"
fi

if [ -n "$DOCKER_WANT" ]; then
  install -m 0755 -d /etc/apt/keyrings
  install_downloaded_file 'the Docker signing key' \
    https://download.docker.com/linux/ubuntu/gpg \
    /etc/apt/keyrings/docker.asc
  # shellcheck disable=SC1091
  . /etc/os-release
  install_managed_config 'the Docker apt source' \
    /etc/apt/sources.list.d/docker.list \
    "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $VERSION_CODENAME stable"
  apt_get update -y
  # shellcheck disable=SC2086  # a package list, deliberately word-split
  apt_install $DOCKER_WANT
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
  warn_existing_containers_keep_log_config
else
  systemctl start docker
fi
DOCKER_GROUP_WAS_PRESENT=0
in_group "$APP_SSH_USER" docker && DOCKER_GROUP_WAS_PRESENT=1
usermod -aG docker "$APP_SSH_USER"
# Recheck for the same reason as the sudo grant above. An operator's
# `Match Group docker` block does not apply until this membership exists.
if ! (
  verify_ssh_hardening "" /etc/ssh "$SSH_RELOAD_STATE" "$APP_SSH_USER" 1 &&
  verify_ssh_key_destination "" "$APP_SSH_USER" "$APP_HOME" "$AUTH_KEYS" &&
  verify_ssh_admission_controls "" "$APP_SSH_USER"
); then
  if [ "$DOCKER_GROUP_WAS_PRESENT" -eq 0 ]; then
    gpasswd -d "$APP_SSH_USER" docker >/dev/null 2>&1 ||
      die "SSH hardening failed after '$APP_SSH_USER' joined docker, and the" \
	"new membership could not be rolled back. Remove it immediately with" \
	"'gpasswd -d $APP_SSH_USER docker'."
    in_group "$APP_SSH_USER" docker &&
      die "SSH hardening failed after '$APP_SSH_USER' joined docker. The rollback" \
	"reported success but the membership is still active; remove it" \
	"immediately with 'gpasswd -d $APP_SSH_USER docker'."
    log "rolled back the new docker membership after SSH hardening verification failed"
  fi
  die "SSH hardening failed after the docker group change. Any membership added" \
    "by this run was rolled back; correct the Match override and re-run."
fi
# Configuration checks are useful diagnostics, but they are not proof that an
# external client can log in. Stage a cutover challenge instead of revoking the
# predecessor here. The installed finalizer accepts it only from an actual SSH
# session as this account, then removes old groups, sudoers and managed keys.
SSH_CUTOVER_PENDING=0
SSH_CUTOVER_NONCE=''
stage_ssh_cutover "$APP_SSH_USER" "$SSH_PUBLIC_KEY"

# --------------------------------------------------------------------------
log "5/9 PostgreSQL $PG_MAJOR"
# --------------------------------------------------------------------------
# Before the apt install, not after: once a second cluster exists it has already
# taken a port, and the only way back is pg_upgradecluster or a delete.
ensure_cluster_on_default_port

if ! [ -d "/etc/postgresql/$PG_MAJOR/main" ]; then
  install -d -m 0755 /usr/share/postgresql-common/pgdg
  install_downloaded_file 'the PostgreSQL signing key' \
    https://www.postgresql.org/media/keys/ACCC4CF8.asc \
    /usr/share/postgresql-common/pgdg/apt.postgresql.org.asc
  # shellcheck disable=SC1091
  . /etc/os-release
  install_managed_config 'the PostgreSQL apt source' \
    /etc/apt/sources.list.d/pgdg.list \
    "deb [signed-by=/usr/share/postgresql-common/pgdg/apt.postgresql.org.asc] https://apt.postgresql.org/pub/repos/apt $VERSION_CODENAME-pgdg main"
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

# Staged and renamed, not written through the live path. `>` truncates at open,
# so an interrupted write leaves a prefix — and a prefix of a PostgreSQL config
# is not a file that fails to load. Every truncation point of the generated
# file, measured against PostgreSQL's own parser (`postgres -C listen_addresses`
# on a scratch cluster with this file included):
#
#   275 truncation points   175 refuse to start (loud)
#                            79 START, with listen_addresses = 'localhost'
#                            21 start with the intended value
#
# Those 79 are the early ones — the comment line and the first directive — and
# they are the quiet failure: the cluster is healthy, `systemctl status` is
# green, and the docker bridge address this file exists to add is simply not
# listened on. The app's containers then cannot reach the database at all, with
# nothing on the host pointing at a truncated config. The run does not even
# reach the restart that would surface it, so the damage waits for a reboot.
PG_CONF_FILE="$PG_CONF_DIR/conf.d/10-collavre.conf"
PG_CONF_REAL="$(resolve_symlink_chain "$PG_CONF_FILE")" || exit 1
PG_CONF_TMP="$(stage_beside "$PG_CONF_REAL")" ||
  die "could not stage $PG_CONF_FILE beside itself. PostgreSQL's configuration" \
      "is unchanged. Check that $PG_CONF_DIR/conf.d is writable and has space," \
      "then re-run."
PG_CONF_HAD_PRIOR=0
PG_CONF_BACKUP=''
if [ -e "$PG_CONF_REAL" ]; then
  PG_CONF_HAD_PRIOR=1
  PG_CONF_BACKUP="$(stage_beside "$PG_CONF_REAL")" || {
    rm -f "$PG_CONF_TMP"
    die "could not preserve the existing $PG_CONF_FILE before replacing it." \
	"PostgreSQL's configuration is unchanged. Check that" \
	"$PG_CONF_DIR/conf.d is writable and has space, then re-run."
  }
fi
# `if ! cat` rather than leaning on the `set -euo pipefail` at the top of this
# file: errexit does cover a bare top-level command, so this is not a live hole
# — but a `|| something` appended to this line later would suppress it silently,
# and what would then be installed is the prefix this exists to keep off the
# live path. The staging file goes with it, so a retry starts from the state a
# kill leaves: PostgreSQL's configuration untouched.
if ! cat > "$PG_CONF_TMP" <<CONF
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
then
  rm -f "$PG_CONF_TMP"
  [ -z "$PG_CONF_BACKUP" ] || rm -f "$PG_CONF_BACKUP"
  die "could not write PostgreSQL's generated configuration — is" \
      "$PG_CONF_DIR/conf.d full? $PG_CONF_FILE is left as it was and the" \
      "cluster is untouched."
fi

# Keep the previous config armed for every exit between replacement and the
# reachability proof. This includes an interrupted run and a failed restart,
# not only the explicit pg_isready branch below.
PG_CONF_ROLLBACK_ARMED=1
trap 'rc=$?
  if [ "${PG_CONF_ROLLBACK_ARMED:-0}" -eq 1 ]; then
    if restore_postgresql_bind_config "$PG_CONF_REAL" "$PG_CONF_BACKUP" "$PG_CONF_HAD_PRIOR"; then
      log "restored the previous PostgreSQL bind configuration after the run stopped"
    else
      rollback_rc=$?
      if [ "$rollback_rc" -eq 2 ]; then
	log "CRITICAL: the previous PostgreSQL bind configuration was restored after the run stopped, but PostgreSQL did not restart on it. Run systemctl restart postgresql immediately."
      else
	log "CRITICAL: the run stopped after replacing $PG_CONF_FILE, and restoring the previous configuration failed. Restore $PG_CONF_BACKUP over $PG_CONF_REAL and restart PostgreSQL immediately."
      fi
    fi
  fi
  exit "$rc"' EXIT
trap 'exit 1' HUP INT TERM

mv -f "$PG_CONF_TMP" "$PG_CONF_REAL"

# Containers authenticate with a password over the docker bridge.
ensure_block "$PG_CONF_DIR/pg_hba.conf" docker \
  "host    all    all    $DOCKER_SUBNETS    scram-sha-256" leading

systemctl enable postgresql
systemctl restart postgresql

# A cluster that is up is not a cluster reachable on the address this run is
# about to publish. refuse_unusable_bind_address answers the shape of
# DB_BIND_ADDRESS before anything is written; it cannot answer whether the
# address is on this host, because docker0 does not exist yet when it runs.
# PostgreSQL will not answer it either — an address it cannot bind is a WARNING
# in a log nobody reads and the cluster starts anyway, listening on localhost
# alone. Measured against a live cluster, which is the only thing that knows:
#
#   listen_addresses            cluster   pg_isready -h <the address>
#   localhost,127.0.0.1         UP        0, accepting connections
#   localhost,1.2.3.4           UP        2, no response
#   localhost,172.17.0.999      UP        2, no response
#
# Asked here rather than believed, because every later step takes it on trust:
# DATABASE_URL, the ufw rule and the summary all name this address, and the
# first thing to discover it is wrong would be the first deploy. pg_isready
# needs no credentials and a pg_hba refusal still counts as a response, so this
# asks about reachability and nothing else.
if ! pg_isready -h "$DB_BIND_ADDRESS" -p "$DB_PORT" -t 10 >/dev/null 2>&1; then
  PG_CONF_ROLLBACK_RC=0
  restore_postgresql_bind_config \
    "$PG_CONF_REAL" "$PG_CONF_BACKUP" "$PG_CONF_HAD_PRIOR" ||
    PG_CONF_ROLLBACK_RC=$?
  PG_CONF_ROLLBACK_ARMED=0
  trap - EXIT HUP INT TERM
  if [ "$PG_CONF_ROLLBACK_RC" -eq 0 ]; then
    die "PostgreSQL restarted, but it did not listen on DB_BIND_ADDRESS=" \
	"$DB_BIND_ADDRESS:$DB_PORT, so the previous bind configuration was" \
	"restored and PostgreSQL was restarted on it. Check the bridge with" \
	"'ip -4 addr show docker0' and set DB_BIND_ADDRESS to its address (the" \
	"default, 172.17.0.1, is the usual one), then re-run with FORCE=1."
  fi
  if [ "$PG_CONF_ROLLBACK_RC" -eq 2 ]; then
    die "PostgreSQL did not listen on DB_BIND_ADDRESS=$DB_BIND_ADDRESS:$DB_PORT." \
	"The previous bind configuration was restored, but PostgreSQL did not" \
	"restart on it. Run 'systemctl restart postgresql' immediately, then" \
	"correct DB_BIND_ADDRESS and re-run with FORCE=1."
  fi
  die "PostgreSQL did not listen on DB_BIND_ADDRESS=$DB_BIND_ADDRESS:$DB_PORT," \
      "and the previous bind configuration could not be restored automatically." \
      "Restore '$PG_CONF_BACKUP' over '$PG_CONF_REAL' and run" \
      "'systemctl restart postgresql' immediately."
fi
PG_CONF_ROLLBACK_ARMED=0
trap - EXIT HUP INT TERM
[ -z "$PG_CONF_BACKUP" ] || rm -f "$PG_CONF_BACKUP"

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

DB_PASSWORD_PENDING_FILE="$STATE_DIR/db_password.pending.$DB_USER"
[ ! -d "$STATE_DIR/db_password" ] ||
  die "$STATE_DIR/db_password is a directory, so the applied password record" \
      "cannot be replaced atomically. PostgreSQL is unchanged. Move that" \
      "directory aside and re-run."
if [ -z "$DB_PASSWORD" ]; then
  if [ -f "$DB_PASSWORD_PENDING_FILE" ]; then
    # A previous run may have committed ALTER ROLE and stopped before promoting
    # the credential record. Reusing the role-specific pending value makes both
    # sides converge whichever side of that commit the interruption reached.
    chmod 0600 "$DB_PASSWORD_PENDING_FILE"
    DB_PASSWORD="$(cat "$DB_PASSWORD_PENDING_FILE")"
    if [ -z "$DB_PASSWORD" ]; then
      die "$DB_PASSWORD_PENDING_FILE exists but is empty, so this host cannot" \
	  "recover the interrupted password update for DB_USER='$DB_USER'." \
	  "Supply DB_PASSWORD explicitly to replace the pending attempt."
    fi
    log "resuming the pending database password update for '$DB_USER'"
  elif [ -f "$STATE_DIR/db_password" ]; then
    # Re-run: keep the password already handed out in DATABASE_URL.
    DB_PASSWORD="$(cat "$STATE_DIR/db_password")"
    # An empty marker is not "no password", it is a password this host can no
    # longer name. Left to fall through, it reaches `ALTER ROLE ... PASSWORD ''`
    # below unconditionally, which rotates the live role to an empty password
    # while the deployed DATABASE_URL still carries the real one — the app meets
    # `password authentication failed` at its next reconnect, several steps
    # after the step that caused it, and the value it needs is gone from the
    # host. Written atomically since this revision, so this answers for a host
    # an earlier one truncated rather than for anything this script can still do.
    if [ -z "$DB_PASSWORD" ]; then
      die "$STATE_DIR/db_password exists but is empty, so this host cannot name" \
          "the password its role is using. Applying it would set the role's" \
          "password to '' and break the deployed DATABASE_URL." \
          "Nothing has been changed. Take the password out of the DATABASE_URL" \
          "the deployment is running with — it is percent-encoded there, so" \
          "decode it — and re-run with DB_PASSWORD=<that value>. If it cannot be" \
          "recovered, re-run with a new DB_PASSWORD= and redeploy with the" \
          "DATABASE_URL this run prints."
    fi
  else
    # URL-safe alphabet only: this password goes into DATABASE_URL verbatim.
    DB_PASSWORD="$(openssl rand -base64 48 | tr -dc 'A-Za-z0-9' | head -c 32)"
    log "generated a random database password"
  fi
fi
if [ -f "$STATE_DIR/db_password" ]; then
  chmod 0600 "$STATE_DIR/db_password"
fi

# Stage the credential under the role it belongs to, but keep the live record
# untouched until psql has applied it. The role name in the path is safe because
# refuse_unusable_db_identifier has already limited DB_USER to [A-Za-z0-9_-].
# Role-specific pending state matters when a run changing both DB_USER and
# DB_PASSWORD is interrupted: a later run naming another role must not apply
# this password to that role merely because it found one unqualified pending
# file.
write_state_file "$DB_PASSWORD_PENDING_FILE" "$DB_PASSWORD" 0600 ||
  die "could not stage the database password in $DB_PASSWORD_PENDING_FILE." \
      "The live password record and PostgreSQL role are unchanged. Check that" \
      "$STATE_DIR is writable and has space, then re-run."

# Mirrors db/setup_postgres_databases.sql: create-if-missing, never drop.
# Collavre keeps primary/cache/queue/cable in ONE database — the Solid Queue,
# Cache and Cable tables are created by a primary db/migrate migration. Do not
# add separate _cache/_queue/_cable databases.
# Before the role is created and made the database's owner, not after. The
# reassignment below and the marker write after it are two steps, and an
# interrupted run between them is what strands a role that owns every table
# with nothing on the host naming it.
record_db_role_grant "$DB_USER" ||
  die "could not record '$DB_USER' in $STATE_DIR/db_users, so this run cannot" \
      "promise that a later one could find the role again. PostgreSQL and the" \
      "live password record are unchanged; the attempted password remains in" \
      "$DB_PASSWORD_PENDING_FILE. Check that $STATE_DIR is writable and has" \
      "space, then re-run with the same DB_USER and no DB_PASSWORD."

SQL_FILE="$(mktemp /tmp/collavre-db.XXXXXX.sql)"
trap 'rm -f "$SQL_FILE"' EXIT
# Doubling the quote through a variable rather than through `\'`, which does not
# mean the same thing on every bash. This is NOT a production defect being
# fixed: on the bash Lightsail runs the previous form was already correct.
# Measured, same input `it's`, same expression `${p//\'/\'\'}`:
#
#   bash 5.2.15  (Ubuntu, what this script runs on; also CI)   it''s
#   bash 3.2.57  (macOS, what a developer runs the suite on)   it\'\'s
#
# Two reasons to spell it this way regardless. The line escapes a credential
# into a SQL literal, and it should not be one whose meaning is decided by the
# interpreter version — on 3.2 psql reads the `\'` as a meta-command and stops
# with "invalid command". The pending record above now makes that failure
# recoverable without advancing the live credential, but it must still be
# escaped consistently so a retry does not stop at the same statement forever.
#
# And it is what lets the suite assert this at all. Case 141 generates with a
# quoted password and checks the statement; against the previous form that
# assertion was green on Ubuntu and red on macOS for a reason having nothing to
# do with the escaping, so it could not be written. Same platform split as the
# `head -c 0` fixture two commits back, pointing the other way.
SQL_QUOTE="'"
ESCAPED_PASSWORD="${DB_PASSWORD//$SQL_QUOTE/$SQL_QUOTE$SQL_QUOTE}"
cat > "$SQL_FILE" <<SQL
\set ON_ERROR_STOP on
SELECT format('CREATE ROLE %I LOGIN', '$DB_USER')
WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname = '$DB_USER')
\gexec
-- LOGIN on the ALTER as well as on the CREATE, because the CREATE is the
-- statement a rotation back to a previous name never reaches. reassign_prior_db_role
-- takes LOGIN from the role it replaces, so after DB_USER goes A -> B -> A the
-- role 'A' exists, the \gexec produces no statement for it, and an ALTER that
-- sets only the password leaves it NOLOGIN. Measured on a real cluster:
--
--   run                  shipped                       with LOGIN here
--   1  DB_USER=a         connects                      connects
--   2  DB_USER=b         connects, a -> NOLOGIN        same
--   3  DB_USER=a         FATAL: role "a" is not        connects
--                        permitted to log in
--
-- Every statement succeeds on that third run, so ON_ERROR_STOP has nothing to
-- stop on and the summary hands out a DATABASE_URL naming a role that cannot
-- open a connection. And run 3 leaves *both* roles NOLOGIN — the rotation
-- correctly disarms 'b' on its way past — so the cluster is left with no
-- application login at all, rather than with a working previous one.
--
-- Idempotent for the ordinary case: LOGIN on a role that has it changes
-- nothing, and this ALTER already ran unconditionally against whatever DB_USER
-- names, so it grants nothing to a role it was not already touching.
ALTER ROLE "$DB_USER" LOGIN PASSWORD '$ESCAPED_PASSWORD';
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
# Both through write_state_file rather than a redirection. `>` truncates before
# it writes, so an interrupted run leaves the marker present and empty — and
# both readers treat an empty marker as "nothing recorded here" rather than as
# "this could not be read", which is the guard answering with the one value it
# has no evidence for.
write_state_file "$STATE_DIR/db_user" "$DB_USER"$'\n' ||
  die "could not record DB_USER='$DB_USER' in $STATE_DIR/db_user. The role and" \
      "database exist and this run has not handed out a DATABASE_URL yet, so" \
      "re-running with the same DB_USER is safe. Check that $STATE_DIR is" \
      "writable and has space."

# psql may commit ALTER ROLE and then fail on a later statement, so the pending
# file remains the recovery record on every non-zero exit above. Promotion also
# waits for ownership reassignment and db_user: the global password record and
# the global role marker must advance as one logical commit. Otherwise a failed
# A -> B rotation followed by the documented rollback to A would read B's new
# password from the global file and apply it to A, breaking A's deployed URL.
# The rename is within $STATE_DIR and therefore atomic.
mv -f "$DB_PASSWORD_PENDING_FILE" "$STATE_DIR/db_password" ||
  die "DB_USER='$DB_USER' is recorded and PostgreSQL accepted its password, but" \
      "the pending credential could not be promoted to" \
      "$STATE_DIR/db_password. The new value is still in" \
      "$DB_PASSWORD_PENDING_FILE; re-run with the same DB_USER and no" \
      "DB_PASSWORD to recover it before redeploying."

# Recorded only once the database it names actually exists, so an interrupted
# run cannot leave a marker for a database that was never created.
write_state_file "$STATE_DIR/db_name" "$DB_NAME"$'\n' ||
  die "could not record DB_NAME='$DB_NAME' in $STATE_DIR/db_name, so a later" \
      "run could not tell a corrected typo from a rename and would refuse." \
      "The database exists and holds the app's data. Check that $STATE_DIR is" \
      "writable and has space, then re-run with the same DB_NAME."

# --------------------------------------------------------------------------
log "7/9 firewall"
# --------------------------------------------------------------------------
# No `ufw reset`: this script is re-runnable, and a reset months later would
# take a VPN, monitoring or IP-allowlist rule with it. Only the rules below are
# ours to converge.
# `default deny incoming` changes an already-active firewall immediately, so
# every public service must be authorized before that live policy is tightened.
ensure_ssh_rule
ufw allow 80/tcp
ufw allow 443/tcp

# PostgreSQL is only listening on localhost and the docker bridge, so this rule
# is defence in depth rather than the only thing keeping it private.
ensure_ufw_rule postgres \
  "allow from $DOCKER_SUBNETS to $DB_BIND_ADDRESS port $DB_PORT proto tcp"
ufw default deny incoming
ufw default allow outgoing
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

# Staged and renamed, not written through the live path, for the reason
# ensure_block already records — with one addition that makes this the worse of
# the two. `cat > /usr/local/bin/collavre-pg-backup` truncates at open, and this
# file is *executable*: a truncated shell script is not a broken file that fails
# to load, it is a shorter program that runs. Every truncation point of the
# generated script, measured:
#
#   1233 truncation points   624 syntactically valid
#                            153 EXIT 0 AND NEVER REACH pg_dump   (bytes 1..310)
#
# Those 153 are the first quarter of the file, so an interruption early in the
# write — the likely one — lands there. And the mode survives: `cat >` does not
# reset it, and the `chmod 0755` below is the *next* statement, so on a re-
# converge run the stump keeps the executable bit the previous run gave it while
# collavre-pg-backup.timer stays enabled. The nightly unit then runs a program
# that exits 0 without dumping anything: systemctl reports green, the retention
# sweep is never reached either, and the host has no backups and no symptom.
# That is why validation is part of the install and not a comment: a file that
# is not a complete script does not get to be the backup program.
BACKUP_TMP="$(mktemp /usr/local/bin/collavre-pg-backup.XXXXXX)"
# `if ! cat` rather than a bare `cat` leaning on the `set -euo pipefail` at the
# top of this file. Errexit does cover a bare top-level command, so this is not
# a live hole — but the review one thread over was exactly a place where `set -e`
# was assumed and was not in force, and a guarantee this local should not depend
# on a setting 2500 lines away that a future `|| something` would suppress. The
# staging file is removed on the way out, so a retry starts from the same state
# a kill would leave: the live path untouched.
# The three configured values are serialized as shell *data* rather than spliced
# in as source. Interpolated into the heredoc, a value is written into the
# generated file verbatim and inside double quotes, so anything shell-significant
# in it is expanded later — by the nightly unit, running as root:
#
#   BACKUP_S3_URI='s3://b/$(...)/db'   the substitution runs at 03:00, as root
#   BACKUP_S3_URI='s3://b/$archive/db' `unbound variable` under the generated
#                                      script's own `set -u` — the backup dies
#
# A legitimate S3 key prefix may contain either. `bash -n` catches neither: both
# forms are perfectly good shell, which is the problem — the validation below
# asks whether the file is a program, not whether it is the intended one.
# %q is the answer to the question the heredoc was answering wrongly.
if ! { printf '%s\n' \
         '#!/usr/bin/env bash' \
         '# Managed by script/lightsail_launch.sh' \
         'set -euo pipefail' \
         'DEST=/var/backups/collavre' &&
       printf 'DB_NAME=%q\nRETENTION_DAYS=%q\nS3_URI=%q\n' \
         "$DB_NAME" "$BACKUP_RETENTION_DAYS" "$BACKUP_S3_URI" &&
       cat <<BACKUP
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
     } > "$BACKUP_TMP"
then
  rm -f "$BACKUP_TMP"
  die "could not write the staged backup script — is /usr/local/bin full?" \
      "/usr/local/bin/collavre-pg-backup is left as it was, and nothing was" \
      "installed over it."
fi
# `bash -n` on the staging file, before it can become the thing systemd runs.
# It is not a whole-program check — 624 of the truncation points above parse
# fine — but it is the half that is free, and the rename below is what closes
# the rest: a run killed during the copy leaves the stump in the staging file
# and the live path untouched, which is the state a retry starts from.
if ! bash -n "$BACKUP_TMP"; then
  rm -f "$BACKUP_TMP"
  die "generated a backup script that is not valid shell — refusing to install" \
      "it over /usr/local/bin/collavre-pg-backup, which is left as it was." \
      "This is a bug in this script; the values it interpolates (DB_NAME," \
      "BACKUP_S3_URI) are the place to look."
fi
chmod 0755 "$BACKUP_TMP"
mv -f "$BACKUP_TMP" /usr/local/bin/collavre-pg-backup

install_managed_config 'the PostgreSQL backup service unit' \
  /etc/systemd/system/collavre-pg-backup.service \
  '[Unit]' \
  'Description=Collavre PostgreSQL dump' \
  'After=postgresql.service' \
  '' \
  '[Service]' \
  'Type=oneshot' \
  'ExecStart=/usr/local/bin/collavre-pg-backup'

install_managed_config 'the PostgreSQL backup timer unit' \
  /etc/systemd/system/collavre-pg-backup.timer \
  '[Unit]' \
  'Description=Nightly Collavre PostgreSQL dump' \
  '' \
  '[Timer]' \
  "OnCalendar=$BACKUP_CALENDAR" \
  'Persistent=true' \
  '' \
  '[Install]' \
  'WantedBy=timers.target'

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
ACTIVE_DEPLOY_USER="$(cat "$STATE_DIR/deploy_user" 2>/dev/null || true)"
if [ -z "$ACTIVE_DEPLOY_USER" ]; then
  ACTIVE_DEPLOY_USER='<finalize SSH cutover first>'
fi

# Rendered twice: once with the real DATABASE_URL into the 0600 summary file,
# once with both credentials redacted for stdout — which is tee'd to the launch
# log and captured by cloud-init. Templating instead of sed'ing secrets out
# keeps a password containing regex or delimiter characters from slipping
# through unreplaced.
render_summary() { # $1 = DATABASE_URL, $2 = SSH cutover nonce to display
  cat <<TXT
Collavre Lightsail host — provisioned $(date -Is)

  public IP        $PUBLIC_IP
  private IP       $PRIVATE_IP
  deploy user      $ACTIVE_DEPLOY_USER
  staged SSH user  $APP_SSH_USER (docker, passwordless sudo)
  PostgreSQL       $PG_MAJOR, listening on localhost + $DB_BIND_ADDRESS only
  database         $DB_NAME owned by $DB_USER
  db password      $STATE_DIR/db_password (root only)$PASSWORD_NOTE
  launch config    $STATE_DIR/launch.env — a re-run applies every setting, so
                   repeat these on the command line or it is refused
  backups          /var/backups/collavre, nightly at $BACKUP_AT, ${BACKUP_RETENTION_DAYS}d retention
  log              $LOG_FILE
TXT

  if [ "${SSH_CUTOVER_PENDING:-0}" -eq 1 ]; then
    cat <<TXT

SSH cutover is pending. The previous deploy account and managed keys remain
privileged until the staged account proves a real SSH login. From the
workstation, using the staged key, run:

  ssh -i ~/.ssh/<staged-key> $APP_SSH_USER@$PUBLIC_IP \\
    "sudo /usr/local/sbin/collavre-finalize-ssh-cutover --finalize-ssh-cutover '$2'"

Only after it prints "SSH cutover finalized" should KAMAL_SSH_USER change to
$APP_SSH_USER. The nonce is one-time; a failed or interrupted finalize is safe
to retry with the same command.
TXT
  fi

  cat <<TXT

Put these in .env.production at the root of your Collavre checkout, then run
\`./kamal.sh setup\` from that same directory — the wrapper is what loads
.env.production; plain \`bin/kamal\` does not read it and would deploy with no
host and the wrong SSH user:

  COLLAVRE_SERVER=$PUBLIC_IP
  KAMAL_SSH_USER=$ACTIVE_DEPLOY_USER
  KAMAL_SSH_KEY_PATH=~/.ssh/<the key matching the instance>
  DATABASE_URL=$1
  PORT=80

Open ports 80 and 443 in the Lightsail console firewall (Networking tab).
Never open 5432 there.
TXT
}

# Render the credential-bearing summary into a root-only sibling and install it
# only after the complete output can be read back. A FORCE re-run may already
# have rotated the database credential, so truncating the live summary would
# destroy the only ready-to-copy, percent-encoded DATABASE_URL for that state.
install_credential_summary() { # $1 = DATABASE_URL, $2 = SSH cutover nonce
  local database_url="$1" cutover_nonce="${2:-}" target_real tmp rc=0
  target_real="$(resolve_symlink_chain "$SUMMARY")" || exit 1
  tmp="$(stage_beside "$target_real" 0600)" || rc=$?
  [ "$rc" -eq 0 ] || {
    die "could not stage the credential summary at $target_real" \
	"(stage_beside exited $rc). The live summary is left exactly as it was."
  }
  if ! chmod 0600 "$tmp"; then
    rm -f "$tmp"
    die "could not make the staged credential summary root-only." \
	"$target_real is left exactly as it was."
  fi
  if ! render_summary "$database_url" "$cutover_nonce" > "$tmp"; then
    rm -f "$tmp"
    die "could not render the staged credential summary — is the instance out" \
	"of disk? $target_real is left exactly as it was."
  fi
  if ! grep -qxF "  KAMAL_SSH_USER=$ACTIVE_DEPLOY_USER" "$tmp" ||
     ! grep -qxF "  DATABASE_URL=$database_url" "$tmp" ||
     ! grep -qxF 'Never open 5432 there.' "$tmp"; then
    rm -f "$tmp"
    die "the staged credential summary is incomplete. Refusing to install it" \
	"over $target_real, which is left exactly as it was."
  fi
  mv -f "$tmp" "$target_real" || {
    rm -f "$tmp"
    die "could not install the staged credential summary over $target_real," \
	"which is left exactly as it was."
  }
}

# What this run was configured with, so the next one can tell an omitted
# override from a deliberate default (refuse_defaulted_config_change). Written
# only here, after every step has succeeded: a run that died halfway must not
# leave a record claiming the host is configured the way it was asked to be.
# No DB_PASSWORD — it has its own 0600 file, and this one is world-readable
# because the answers in it ("which deploy user?", "which database?") are what
# the runbook sends operators here to read.
#
# Through an atomic write, and fatal unless a complete prior record survives:
# the reader treats a missing line as a setting it has nothing to say about, so
# a later bare FORCE=1 could otherwise reset an unrecorded BACKUP_S3_URI while
# this run still created the success marker.
record_launch_settings

install_credential_summary "$DATABASE_URL" "${SSH_CUTOVER_NONCE:-}"

touch "$MARKER"
render_summary "$REDACTED_URL" '<see root-only summary>'
log "done — full log at $LOG_FILE (root only; the DATABASE_URL above is redacted, the real one is in $SUMMARY)"
