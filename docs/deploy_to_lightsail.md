# Deploy to AWS Lightsail (app + PostgreSQL on one instance)

This runbook provisions a single Lightsail instance that runs both PostgreSQL
and the Collavre container, deployed with Kamal from your workstation.

[`script/lightsail_launch.sh`](../script/lightsail_launch.sh) does the host
preparation. It never builds or starts the app — `./kamal.sh setup` does that.

| The launch script sets up | You still do |
| --- | --- |
| Base packages, timezone, swap, SSH hardening | Lightsail console firewall (80/443) |
| Deploy user in the `docker` group | `.env.production` on your workstation |
| Docker CE + buildx + compose, capped container logs | `./kamal.sh setup` |
| PostgreSQL, private to this host | Loading the schema / restoring data |
| `collavre_production` + `collavre_user` | DNS and TLS |
| ufw, nightly `pg_dump` with retention | |

## 1. Pick an instance

Puma, Solid Queue (in-Puma) and PostgreSQL share one box, so **4 GB RAM / 2 vCPU
is the practical floor**; 2 GB works only for a light pilot. The script adds a
2 GB swap file either way. Blueprint: **Ubuntu 24.04 LTS**.

> **Check the CPU architecture.** `config/deploy.yml` sets `builder.arch: arm64`
> for the current Graviton host. Lightsail's standard Linux plans are x86-64, so
> run `uname -m` on the new instance: if it prints `x86_64`, set
> `builder: arch: amd64`. Building an amd64 image on an Apple Silicon Mac runs
> under emulation and is slow — either accept it once per deploy, or build on
> the instance itself:
>
> ```yaml
> builder:
>   arch: amd64
>   remote: ssh://<deploy-user>@<instance-ip>
> ```
>
> The launch script installs buildx, so the remote builder works out of the box.
> Remote builds on a 4 GB instance need the swap file the script creates.

## 2. Create the instance with the launch script

Copy the contents of `script/lightsail_launch.sh` into the **Launch script** box
(Lightsail console → Create instance → *Add launch script*). Edit the
configuration block at the top first — at minimum `SSH_PUBLIC_KEY`, unless you
are happy for the deploy user to reuse the key Lightsail installs for `ubuntu`.

Common overrides:

| Variable | Default | Notes |
| --- | --- | --- |
| `SSH_PUBLIC_KEY` | *(empty)* | Empty = copy `ubuntu`'s `authorized_keys`. [Changing it on a re-run](#rotating-ssh_public_key-on-a-re-run) stages the new key; the old key is withdrawn only after an SSH-session proof |
| `APP_SSH_USER` | `collavre` | Becomes `KAMAL_SSH_USER` only after the SSH cutover is finalized. Gets passwordless sudo because the maintenance commands below are non-interactive. [Changing it on a re-run](#changing-app_ssh_user-on-a-re-run) is a two-phase cutover |
| `PG_MAJOR` | `17` | Match the source database when restoring a dump. [Changing it on a re-run](#changing-pg_major-on-a-re-run) is refused, not converged |
| `DB_PASSWORD` | *(generated)* | Generated password is alphanumeric; a custom one is [percent-encoded into `DATABASE_URL`](#a-custom-db_password-is-percent-encoded-in-database_url) |
| `DB_USER` | `collavre_user` | [Changing it on a re-run](#changing-db_user-on-a-re-run) moves table ownership to the new role and takes `LOGIN` from the old one |
| `SWAP_SIZE_MB` | `2048` | `0` disables |
| `BACKUP_S3_URI` | *(empty)* | e.g. `s3://collavre-backups/pg` — PostgreSQL only, [not uploaded files](#backup_s3_uri-does-not-cover-uploaded-files) |

`DB_NAME` and `DB_USER` must be letters, digits, `_` and `-`, not starting with
`-`; anything else is refused before the run starts. PostgreSQL itself is more
permissive — the script creates both through `format('%I')`, which quotes
whatever it is given — but `DB_NAME` is also a *filename*: the nightly dump is
written to `/var/backups/collavre/$DB_NAME-<stamp>.dump`, so a `/` in the name
puts it under a directory that does not exist and every backup fails on a host
that otherwise runs perfectly well.

It also runs fine by hand on an existing instance, and re-running converges the
host instead of duplicating config:

```bash
sudo SSH_PUBLIC_KEY="ssh-ed25519 AAAA..." bash script/lightsail_launch.sh
# after the first success — repeat what you gave it, including the key:
sudo SSH_PUBLIC_KEY="ssh-ed25519 AAAA..." FORCE=1 bash script/lightsail_launch.sh
```

If a re-run adds or changes Docker's default log caps, it restarts Docker but
cannot retrofit those defaults onto existing containers. Recreate them with
`./kamal.sh deploy` from your workstation; until that deployment, their
previous logging configuration remains in effect.

**A re-run applies every setting in the table, not only the ones you name.** An
override you used the first time and did not repeat is applied as its default,
and three of those defaults do not converge the host — they rotate it.
`APP_SSH_USER` back to `collavre` stages a new account and an SSH cutover;
`DB_USER`
back to `collavre_user` moves table ownership and takes `LOGIN` from the role
in the deployed `DATABASE_URL`. An omitted `SSH_PUBLIC_KEY` means "reuse the
cloud user's key", so the run copies `ubuntu`'s `authorized_keys` into the
deploy account — the account with passwordless `sudo` and `docker` — which is
why the bare `sudo FORCE=1 bash script/lightsail_launch.sh` you may have run
before now stops instead: on a host provisioned with the line above, that is
the ordinary re-run, and the widening is what it would do first. A defaulted
`BACKUP_S3_URI` is the quiet one: it regenerates the nightly job without the
upload, so dumps keep being written and stop leaving the instance.

So the re-run is refused when a setting it was *not given* disagrees with what
the host was provisioned with. Giving the value is what makes it an
instruction, so the deliberate rotations documented below are never refused;
only the omission is. The refusal changes nothing and prints the command that
converges the host as it stands:

```
!!! REFUSING: this run would change settings it was not asked to change.
    APP_SSH_USER: host has 'deploybot', this run would apply 'collavre'
    BACKUP_S3_URI: host has 's3://collavre-backups/pg', this run would apply ''
...
    sudo APP_SSH_USER=deploybot BACKUP_S3_URI=s3://collavre-backups/pg FORCE=1 bash script/lightsail_launch.sh
```

`ACK_CONFIG_RESET=1` goes ahead with the defaults, for when resetting them is
what you meant. The host's own record is `/var/lib/collavre/launch.env`, which
is also the answer to "what did I provision this with?" — read it before a
re-run rather than after one. On a host provisioned before that file existed,
`APP_SSH_USER` and `DB_USER` are still checked, against
`/var/lib/collavre/deploy_user` and `/var/lib/collavre/db_user`; the rest are
unknowable until the next successful run records them.

Converging means the firewall too: a re-run adds and updates only the rules the
script owns (SSH, 80, 443, and 5432 from the Docker bridge), so a VPN,
monitoring or IP-allowlist rule you added by hand survives it. Two consequences
worth knowing before you re-run:

- If you have narrowed SSH — `ufw allow from <your-ip> to any port 22` with the
  blanket rule deleted — the script leaves it alone rather than re-opening 22.
  It only adds its own SSH rule when nothing else allows the port. `ufw limit`
  counts as allowing it: rate-limiting SSH is what ufw's own documentation
  recommends, and a `LIMIT` rule is an allow rule with a throttle on it.
- It does reassert `default deny incoming` and `default allow outgoing`. That
  is the only setting a re-run tightens on you, and a service reachable solely
  because the default policy was loosened will stop being reachable.

Progress: `sudo tail -f /var/log/collavre-launch.log` (first boot takes 3–6
minutes). When it finishes it writes `/root/collavre-lightsail-summary.txt` with
the generated `DATABASE_URL` and the exact `.env.production` lines to copy.

The summary is also printed to the launch log, but with the database password
redacted — the log and cloud-init's copy of it are not the place for a
credential. Read the real `DATABASE_URL` from the `0600` summary file (or the
password alone from `/var/lib/collavre/db_password`).

**In the console firewall (Networking tab): open 80 and 443. Never open 5432.**

**Leave 80 and 443 closed until [§5](#5-get-data-into-the-new-database) is
finished**, if you are bringing existing data or doing a fresh install. `setup`
boots the app, and the recipes in §5 stop it again and replace the schema
underneath — so between those two points a reachable instance is serving a
database that is about to be discarded. `app stop` closes the window in which
the *app* writes; it cannot close the one before it. Anything a visitor does in
that interval — a signup, a password reset — is thrown away by the schema
replacement without ever failing visibly. Open them once §5 is done; TLS
([§7](#7-tls)) needs 443 reachable, so that is the point at which it has to be
open, and nothing before it is waiting on it.

### A custom `DB_PASSWORD` is percent-encoded in `DATABASE_URL`

The generated password is alphanumeric, so it appears in `DATABASE_URL`
unchanged. A password you supply yourself may not be — and the failure is not
the loud one it looks like it should be. Measured against the resolver Rails
actually uses (`ActiveRecord::DatabaseConfigurations::ConnectionUrlResolver`):

```
p@ss        URI::InvalidURIError    (likewise p#ss, p?ss, p%ss, "p ss")
p@ss/word   parses — host "ss", database "word@172.17.0.1:5432/collavre_production"
pa%41ss     parses — password "paAss"
```

Only a password with a *single* offending character aborts the boot. One
holding `@` **and** `/` parses cleanly into a different host and a different
database name, so the container fails to resolve a hostname in the middle of a
deploy with nothing on screen pointing at the password. One containing a valid
percent-escape is decoded, so Rails authenticates with a different string than
the one in `/var/lib/collavre/db_password` — and reports only that the password
was rejected.

So the script percent-encodes the role, password and database name when it
composes the URL. Rails decodes them again when it resolves the connection, so
the role still authenticates with the literal password it was created with. The
practical consequence is only that the two do not look alike:

```
/var/lib/collavre/db_password   p@ss/word
DATABASE_URL                    postgresql://collavre_user:p%40ss%2Fword@172.17.0.1:5432/collavre_production
```

Copy `DATABASE_URL` from the summary file as-is. Do not paste the raw password
into it.

### Changing `APP_SSH_USER` on a re-run

A `FORCE=1` re-run with a different `APP_SSH_USER` is deliberately a two-phase
cutover. The provisioning phase creates and hardens the new account, installs
its key, and grants `docker` plus passwordless `sudo`, but leaves the old
account and its managed keys unchanged. Configuration analysis cannot prove
that an external client can log in: `Match`, `Include`, admission rules, key
paths, source addresses, and future sshd directives make that an open-ended
problem.

The root-only summary therefore contains a one-time signed command like this:

```bash
key=~/.ssh/<staged-key>
nonce='<nonce>'
signature="$(printf 'collavre-ssh-cutover:%s:%s' '<new-user>' "$nonce" |
  ssh-keygen -Y sign -f "$key" -n collavre-ssh-cutover 2>/dev/null |
  base64 | tr -d '\n')"
ssh -i "$key" <new-user>@<instance-ip> \
  "sudo /usr/local/sbin/collavre-finalize-ssh-cutover \
    --finalize-ssh-cutover '$nonce' '$signature'"
```

Run that exact command from the workstation with the key Kamal will use. The
local `ssh-keygen` signs the nonce and staged username with that private key;
the signature travels only as an argument to the SSH command, so a failed
staged-account login never invokes the finalizer. The host verifies the
signature against the public keys captured atomically when the cutover was
staged. This is the security boundary: the predecessor is root-equivalent and
can forge host-local process names, environment variables, and files, but it
cannot synthesize the workstation's private-key signature. For an explicit key
rotation, only that exact staged key is accepted; for copied cloud keys, any
valid key installed for the successor may sign. The nonce hash, accepted
signing keys, fingerprint, and exact rotation key live in one atomic root-only
pending record so an interrupted re-run cannot mix cutover generations. Only
then does the finalizer take `docker` and `sudo` from every predecessor,
remove their script-managed
`sudoers.d` grants, withdraw predecessor managed keys, and commit
`/var/lib/collavre/deploy_user`. Change `KAMAL_SSH_USER` only after the command
prints `SSH cutover finalized`.

If provisioning or proof fails before the successor marker is committed, the
old account and managed keys remain unchanged. After successful proof, the
successor marker is committed before any predecessor is disarmed. If later
key/group/sudoers cleanup is interrupted, the proven successor remains the
recovery path, `/var/lib/collavre/ssh_cutover.pending` remains, and the same
finalize command safely retries the remaining cleanup. A different target
cannot be staged over a pending cutover; finish the recorded transition first.
This is intentional availability bias: a reported stale credential is safer
than automatically removing the last proven way into the host.

Docker membership is the part that makes finalization security-sensitive:
`docker run -v /:/host` is a root shell, so an account left in that group has
not been rotated away from in any meaningful sense — it has only lost the
slower route.

Every account the script grants those groups to is recorded in
`/var/lib/collavre/deploy_users` **before** the grant is made, and a name leaves
that file only once the host confirms it holds neither group. Both halves are
load-bearing. Recorded before, because the grants are in step 3 and step 4 while
the revocation is at the end of step 4 — a run interrupted across the Docker
install would otherwise leave the new account holding root-equivalent access
with nothing on the host naming it. A list rather than one name, because a
revocation that fails has to be retried without pinning the record to the
account it failed on: pinning it is how a second rotation walks past the account
in between and loses it. `/var/lib/collavre/deploy_user` still names the current
deploy user, which is what the recipes on this page read.

What the finalizer will not do is delete the account or unmanaged keys in its
`authorized_keys`. If
the name it replaced were ever the instance's own cloud user, deleting it would
remove the last way in. So the run leaves an ordinary, group-less account behind
and says so in the launch log. Finish the rotation by hand once you have
confirmed you can reach the host as the new user:

```bash
ssh <new-user>@<instance-ip> 'sudo deluser --remove-home <old-user>'
```

### Changing `PG_MAJOR` on a re-run

This is the one setting a re-run refuses instead of converging, and the reason
is that converging it would look like it worked.

The script assumes a single cluster on port 5432 — `DATABASE_URL`, the ufw rule
and the nightly `pg_dump` all name it. Ubuntu's `postgresql-common` makes no
such assumption: `pg_createcluster` takes the first free port from 5432 upward,
so installing a second major version puts it on 5433. The run would then tune
and configure `/etc/postgresql/<new>/main` while `psql` — and therefore the
database, the role, the backups and the URL you paste into `.env.production` —
went on talking to whatever answers on 5432. Nothing fails. The log says the new
version, the app keeps running on the old cluster, and the new one sits empty
holding a quarter of the instance's RAM in `shared_buffers`.

So a re-run whose `PG_MAJOR` is not the version already serving 5432 aborts
before `apt` can create the second cluster, and names both versions. A real
major upgrade is a deliberate, app-down operation:

```bash
sudo cat /var/lib/collavre/launch.env          # read this BEFORE the app goes down; see below
./kamal.sh app stop
sudo apt-get install -y postgresql-<new>       # the script will not install it while 5432 is taken
sudo pg_dropcluster --stop <new> main          # apt just created an EMPTY one; it is not the upgrade
sudo pg_upgradecluster <old> main              # copies the data, and gives the new cluster 5432
sudo pg_dropcluster --stop <old> main
sudo <every setting in launch.env> FORCE=1 PG_MAJOR=<new> bash script/lightsail_launch.sh
./kamal.sh app boot
```

The first line is there because the second-to-last one is a re-run, and a re-run
that omits a setting this host was provisioned with
[is refused](#2-create-the-instance-with-the-launch-script) rather than allowed
to reset it. `PG_MAJOR=<new>` alone is exactly that omission on any host given
so much as an `SSH_PUBLIC_KEY`. The refusal changes nothing and prints the line
that clears it, so this costs a paste — but it arrives with the app stopped and
the old cluster already dropped, which is the wrong moment to be reading a file
you could have read before the outage. On a host provisioned before `launch.env`
existed, `sudo cat /var/lib/collavre/deploy_user` and `.../db_user` are what the
host can still answer.

The `pg_dropcluster --stop <new> main` line is the one that is easy to skip and
expensive to skip — named rather than numbered, because it is the step whose
absence is invisible until it is too late. Installing
the package auto-creates an empty `<new>/main` on the next free port, and
`pg_upgradecluster` then stops with `target cluster <new>/main already exists`
rather than upgrading into it. `pg_upgradecluster` itself moves the old cluster
aside and hands 5432 to the new one, so the re-run at the end passes the check
above; verify with `sudo pg_lsclusters` before booting — exactly one cluster, on
5432, at the new version.

### Rotating `SSH_PUBLIC_KEY` on a re-run

The third member of the same family, on the same account. A re-run with a
different `SSH_PUBLIC_KEY` adds the new key, and without anything further the
old one stays in `authorized_keys` — and that account is in `docker` with
passwordless sudo, so the key you believed you retired is still root on the
box. Rotating away from a leaked key would have withdrawn nothing while
reporting success.

The run therefore adds the new key but does not withdraw its predecessor.
Instead it creates the same pending SSH cutover described above. Connect with
the new private key and run the nonce-bearing finalize command from the
root-only summary. That real session is the safety boundary: only after it
succeeds does the finalizer withdraw the key recorded in
`/var/lib/collavre/ssh_public_key.<user>`. Only exact script-managed lines go;
keys added by hand and the cloud user's original key are left alone.

The record is **per account**, because `authorized_keys` is. Changing
`APP_SSH_USER` and changing back is the case that needs it: rotating
`collavre`/key-A to `deploybot`/key-B leaves key-A in `collavre`'s file, which is
correct — that is not the file being rewritten, and the finalized cutover takes
`docker` and sudo away from `collavre`. But coming back later to
`collavre`/key-C regrants those privileges, and with one shared record the
withdrawal would be looking for key-B, which was never in that file. Key-A would
be root again, two rotations after you retired it. A host provisioned by an
earlier revision has its single `ssh_public_key` file adopted by the account the
next run names. The withdrawal happens only after the new key has completed an
SSH session, so an interrupted run leaves two working keys rather than none.

Two cases deliberately do nothing. A re-run with `SSH_PUBLIC_KEY` unset means
"keep using the cloud user's keys", not "retire mine" — dropping the variable
from a re-run is easy, and treating it as a rotation would strand you. And if
the rewrite cannot be completed (a full disk is the realistic way), the script
says so, leaves the old key authorized, and leaves the marker alone so the next
run tries again. Both directions are the safe one: the cost is a key that
outlives its rotation and is reported, rather than a host with no key at all.

### Changing `DB_USER` on a re-run

The database counterpart of the above, and it fails in a quieter way. Creating
the new role and pointing `ALTER DATABASE ... OWNER` at it moves the *database*
and nothing inside it: every table and sequence the app has already created
stays owned by the old role. The re-run reports success, prints a `DATABASE_URL`
naming the new role, and that role gets `permission denied for table ...` on its
first query. Meanwhile the old role keeps `LOGIN` and the same password out of
`/var/lib/collavre/db_password`, so a rotation meant to retire a credential
retires nothing.

So a re-run that changes `DB_USER` also runs `REASSIGN OWNED BY <old> TO <new>`
in `$DB_NAME` and then `ALTER ROLE <old> NOLOGIN`. Ownership of everything the
old role owns moves in one statement, and the old login stops working before the
new URL is published. The role itself is left in place — `NOLOGIN` is reversible
and dropping it is not.

**One case stops the run rather than converging: a previous `DB_USER` that is a
superuser** (`DB_USER=postgres` on a first run is legal). Two separate reasons,
and neither has a fix the script can apply:

- `NOLOGIN` on the cluster superuser locks every operator out of administering
  it — peer authentication needs `LOGIN` too, so there is no way back in.
- PostgreSQL refuses to reassign a superuser's objects at all:
  `cannot reassign ownership of objects owned by role postgres because they are
  required by the database system`. So the new role would own the database and
  not one table in it.

The run stops before anything moves, with `/var/lib/collavre/db_user` still
naming the old role so a later re-run sees the same state. Move the application
objects by hand, then re-run.

Both blocks below operate on one database, so resolve its name once from the
host's own record rather than assuming the default — an operator who followed
[the rename procedure](#changing-db_name-on-a-re-run), or who provisioned with
`DB_NAME`, does not have `collavre_production`:

```bash
app_db=${app_db:-$(sudo cat /var/lib/collavre/db_name 2>/dev/null)}
if [ -z "$app_db" ]; then
  echo "REFUSING: could not read the database name from"
  echo "  /var/lib/collavre/db_name — nothing below will operate on the"
  echo "  right database. Name it and paste this block again:"
  echo "    app_db=<the database>"
else
  echo "operating on: $app_db"
fi
```

It refuses rather than falling back, and an empty name is the reason: `psql -d ''`
connects to the `postgres` database and exits `0`, so a fallback would run the
transfer below against a database with no application tables in it and report
success from both blocks.

```bash
sudo -u postgres psql -v ON_ERROR_STOP=1 -d "$app_db" <<'SQL'
DO $$
DECLARE r record;
BEGIN
  FOR r IN
    SELECT c.oid::regclass AS obj
    FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
    -- `pg_toast` is absent from this list on purpose, and the `relkind` filter
    -- is why: TOAST relations are relkind 't' and their indexes 'i', so
    -- neither is selected here. Measured on a cluster with a toastable table,
    -- pg_toast holds 39 't' and 39 'i' and no 'r' at all. Adding it would be a
    -- second no-op that implies the filter below is not trusted.
    WHERE n.nspname NOT IN ('pg_catalog', 'information_schema')
      AND c.relkind IN ('r', 'p', 'S', 'v', 'm')
      AND pg_get_userbyid(c.relowner) = 'postgres'
      -- A sequence owned by a table column follows its table; altering it
      -- directly is an error, so leave those to the table's own ALTER.
      AND NOT EXISTS (
        SELECT 1 FROM pg_depend d
        WHERE d.objid = c.oid
          AND d.classid = 'pg_class'::regclass
          AND d.deptype = 'a')
  LOOP
    EXECUTE format('ALTER TABLE %s OWNER TO %I', r.obj, 'collavre_app');
  END LOOP;
END $$;
SQL
```

Substitute your new `DB_USER` for `collavre_app`. `postgres` keeps `LOGIN` and
its superuser rights — that is the point of doing it here rather than in the
script. Check before re-running that nothing is left behind:

```bash
left="$(sudo -u postgres psql -qtA -d "$app_db" -c \
  "SELECT relkind, relname FROM pg_class c
     JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname NOT IN ('pg_catalog','information_schema','pg_toast')
      AND c.relkind IN ('r','p','S','v','m')
      AND pg_get_userbyid(c.relowner) = 'postgres'")" && asked=yes || asked=no

if [ "$asked" != yes ]; then
  echo "COULD NOT CHECK $app_db — the query itself failed, so nothing is proven."
elif [ -n "$left" ]; then
  echo "STILL OWNED BY postgres — the transfer is unfinished:"
  echo "$left"
else
  echo "TRANSFER COMPLETE: re-run the script and the rotation goes through."
fi
```

The verdict is gated on the query having been answered, not on its output being
empty. A `psql` that cannot connect — the database was renamed, the cluster is
down — prints its `FATAL` on stderr and leaves stdout empty, which is the same
thing a completed transfer looks like. "Could not be checked" is not "checked
and clear". The `relkind` filter is not tidiness: without it the query returns
several dozen catalog TOAST tables and their indexes, which `postgres` owns on
every cluster, so it could never come back empty and would report a completed
transfer as unfinished. Indexes and TOAST tables have no ownership of their own;
they follow the table they belong to. Measured on a cluster with one toastable
table: 81 rows with neither filter, 2 with `relkind` alone. `pg_toast` here is
belt-and-braces rather than load-bearing — the transfer loop above leaves it out
for that reason, since TOAST relations are `relkind` `'t'` and never reach it.

`postgres` keeps `LOGIN`, its password in `/var/lib/collavre/db_password` and
its superuser rights after the rotation, and the script says so when it lets one
through. That is the part this procedure cannot do for you: an ordinary rotation
ends with `ALTER ROLE <old> NOLOGIN`, and the same statement aimed at the
cluster superuser is a lockout rather than a revocation — PostgreSQL accepts it,
after which every connection as `postgres` is refused with `FATAL: role
"postgres" is not permitted to log in`, peer authentication included. Decide
separately what should happen to that login; the script will not touch it.

Setting `DB_USER` back to the old value is the other way out, and leaves the
rotation undone.

Rotating the *password* rather than the role needs none of this — set
`DB_PASSWORD`, re-run, and update `DATABASE_URL`.

### Changing `DB_NAME` on a re-run

**Refused, like `PG_MAJOR`.** The database SQL is create-if-missing, so a
re-run with a different `DB_NAME` would make a second, empty database and leave
the first exactly where it is. Nothing fails: the summary, `DATABASE_URL` and
the nightly backup all move to the new name, so the app boots with no data and
the backup starts dumping the empty database while the real one sits there
referenced by nothing and no longer protected.

The name a run used is recorded in `/var/lib/collavre/db_name`, and a re-run
that disagrees with it stops before anything is created. On a host provisioned
before that file existed the run falls back to the cluster: if the database
`DB_NAME` names is already there it is adopted and recorded, and if it is not,
the run stops and lists the databases that do exist rather than guessing
whether you are correcting a typo or renaming.

To actually move to a new name, do it deliberately and then tell the script:

```bash
# on the instance, with the app stopped from your workstation:
#   ./kamal.sh app stop
#
# One chain, so the marker cannot move past a rename that did not happen. As
# two statements a failed ALTER — a session that survived `app stop` is the
# usual cause, and its error scrolls past in an interactive shell with no
# `set -e` — still records the new name, and the next launch-script run then
# trusts that marker and creates an empty database under it. That is the
# outcome this whole section exists to prevent, reached from the other side.
#
# The existence check is not redundant with the ALTER's status: it is what makes
# the marker describe the cluster rather than describe a command that reported
# success. `grep -qx` is the gate rather than psql's own status, so an empty
# answer — a query that failed, a cluster that went away — fails closed.
# Both names are double-quoted because you are substituting your own into them,
# and DB_NAME accepts names an unquoted identifier cannot carry: the launch
# script creates them through `format('%I')`, so `collavre-prod` is legal there
# and a syntax error here without the quotes.
sudo -u postgres psql -qd postgres -c \
  "ALTER DATABASE \"collavre_production\" RENAME TO \"collavre_prod\"" &&
  sudo -u postgres psql -qtAd postgres -c \
    "SELECT 1 FROM pg_database WHERE datname = 'collavre_prod'" | grep -qx 1 &&
  echo collavre_prod | sudo tee /var/lib/collavre/db_name
```

`RENAME TO` needs no other session connected — which is why the app has to be
stopped first — and it keeps the same data, owner and grants, so nothing else
has to be reissued. Update `DATABASE_URL` in `.env.production` to the new name
and redeploy.

**Then re-run the launch script with `DB_NAME=collavre_prod`.** That re-run is
not optional. `/usr/local/bin/collavre-pg-backup` had the old name written into
it when the script generated it, and redeploying the *application* does not
regenerate a *host* script — so the nightly timer keeps calling `pg_dump` on a
database that no longer exists. It fails, `collavre-pg-backup.service` goes red,
and nothing new lands in `/var/backups/collavre`: the one failure on this page
you discover by needing a dump and not having one. Pass the name explicitly,
because `DB_NAME` still defaults to `collavre_production` and a plain re-run is
now refused by the marker you just wrote. Any *other* override this host was
provisioned with has to be repeated on that same command line — the re-run
[stops and lists them](#2-create-the-instance-with-the-launch-script) rather
than resetting them, so you are told, but being told mid-rename is worse than
reading `/var/lib/collavre/launch.env` first. If you would rather not re-run
provisioning, edit the `DB_NAME=` line in `/usr/local/bin/collavre-pg-backup`
and prove it rather than assume it:

```bash
# The unit is Type=oneshot, so `start` blocks until it finishes and its own
# status is the answer — `is-active` is not, because a oneshot that succeeded
# reports "inactive" once it exits.
sudo systemctl start collavre-pg-backup.service ||
  systemctl status --no-pager collavre-pg-backup.service
ls -l /var/backups/collavre
```

Copying instead of renaming (a `pg_dump` into a new database) is the other
option, and then the old one is yours to drop once you have checked the copy.

### Changing `SWAP_SIZE_MB` on a re-run

A re-run compares the size of `/swapfile` on disk, so raising or lowering the
value resizes it and `SWAP_SIZE_MB=0` removes it. Two cases stop short of that,
both reported and neither fatal, because raising this is usually a response to
memory pressure and a run that aborts — or that leaves the host with less swap
than it had — makes the thing it was called about worse:

- **`swapoff` fails.** The pages cannot be faulted back into RAM, which is
  precisely the low-memory condition being fixed. The old swap keeps running,
  unchanged. Free some memory and re-run.
- **The new size does not fit on the disk.** Growing means freeing the old file
  first, so the previous size is re-created and re-enabled instead. Grow the
  disk or lower `SWAP_SIZE_MB`, then re-run.

In both cases the log says the value did not take effect and what is running
instead. A *first* run that cannot allocate has nothing to fall back to and
stops the provisioning run.

## 3. How PostgreSQL is reachable

PostgreSQL listens on `localhost` and `172.17.0.1` — the docker0 bridge
gateway — and nothing else. Every container on the host can reach that address;
nothing off the host can, whatever the firewalls say. `pg_hba.conf` requires
`scram-sha-256` from the Docker ranges, and ufw only allows 5432 from
`172.16.0.0/12` to that one address.

```
DATABASE_URL=postgresql://collavre_user:<password>@172.17.0.1:5432/collavre_production
```

`net.ipv4.ip_nonlocal_bind=1` is set so PostgreSQL can bind `172.17.0.1` after a
reboot even if it starts before dockerd creates the bridge.

Collavre keeps **everything in one database**: the Solid Queue / Cache / Cable
tables come from a primary `db/migrate` migration, and only `DATABASE_URL` is
set, so `cache`, `queue` and `cable` connect to the same database. Do not create
separate `_cache` / `_queue` / `_cable` databases — see the header comment in
[`db/setup_postgres_databases.sql`](../db/setup_postgres_databases.sql).

## 4. Deploy

On your workstation, in `.env.production`:

```dotenv
COLLAVRE_SERVER=<instance public IP>
KAMAL_SSH_USER=<the KAMAL_SSH_USER value from the summary file>
KAMAL_SSH_KEY_PATH=~/.ssh/<key matching the instance>
KAMAL_REGISTRY_USER=<docker hub user>
KAMAL_REGISTRY_PASSWORD=<docker hub access token>
DATABASE_URL=<the DATABASE_URL line from the summary file, copied verbatim>
PORT=80
SOLID_QUEUE_IN_PUMA=true
```

Copy the generated `KAMAL_SSH_USER=...` line from the summary file rather than
assuming the default `collavre` account. It reflects the `APP_SSH_USER` that
actually received the SSH key, Docker access and passwordless sudo.

`DATABASE_URL` is the one value here you must not compose yourself: the script
already wrote it, [percent-encoded](#a-custom-db_password-is-percent-encoded-in-database_url),
into the 0600 summary file. Assembling it from `/var/lib/collavre/db_password`
puts the raw password into a URL, which — as measured above — is as likely to
resolve to the wrong host as it is to fail outright.

Keep the rest of `env.template` in mind — `RAILS_MASTER_KEY`, `SECRET_KEY_BASE`,
the `ACTIVE_RECORD_ENCRYPTION_*` keys and the OAuth/S3/FCM credentials all still
have to be set. Then:

```bash
./kamal.sh setup      # first deploy: bootstraps the server and boots the app
./kamal.sh deploy     # subsequent deploys
./kamal.sh logs
```

`kamal.sh` wraps `bin/kamal` with `.env.production` loaded, and is the only
thing that reads that file — `bin/kamal setup` on its own sees an empty
`COLLAVRE_SERVER` and falls back to the default `deploy` SSH user. Run it from
the repo root (the wrapper's paths are relative) with `RAILS_ENV` unset or
`production`, since it loads `.env.$RAILS_ENV`.

## 5. Get data into the new database

`bin/docker-entrypoint` runs `db:migrate` on boot. On a brand-new database that
replays every migration from zero, and `db/schema.rb` is known to drift from a
full replay — so if you are bringing existing data, **load it before the app
serves a request**. Which side of `./kamal.sh setup` that falls on depends on
the source: a PostgreSQL dump goes in over SSH before the first deploy, while
the SQLite converter and the fresh-install schema load both need the app image
and so run after it — with `./kamal.sh app stop` first, since `setup` leaves a
container polling the database they are about to replace.

`<deploy-user>` in the recipes below is `APP_SSH_USER` — `collavre` unless you
overrode it, in which case it is the value you set and also what
`KAMAL_SSH_USER` in `.env.production` has to say. It is written as a placeholder
rather than spelled `collavre` because only that account is guaranteed to hold
the key, the passwordless sudo grant and the `docker` membership these commands
need; the instance also has its own `ubuntu` cloud user, and `collavre` may not
exist at all. `sudo cat /var/lib/collavre/deploy_user` on the instance is the
host's own answer if you are unsure.

`<db-user>` and `<db-name>` are the same kind of placeholder, for the same
reason: `DB_USER` and `DB_NAME` are overridable at provisioning time, and
`DB_NAME` also changes under the [rename procedure](#changing-db_name-on-a-re-run).
A role that does not exist fails these recipes at their first statement, and a
database name that does not exist is worse in the import below, which creates
nothing and reports the miss as a connection error. The instance answers for
both, and the launch summary repeats them:

```bash
sudo cat /var/lib/collavre/db_user   # <db-user>
sudo cat /var/lib/collavre/db_name   # <db-name>
```

- **Moving an existing PostgreSQL deployment (Neon, RDS):** dump and restore.
  Match `PG_MAJOR` to the source server's major version or the restore may fail.

  **Stop writes to the source before the final dump.** `pg_dump` takes a
  consistent snapshot of the moment it starts, so every transaction committed
  after that — a signup, an edit, a job enqueued — is in the old database and
  not in `collavre.dump`. Nothing later in this procedure notices: the restore
  succeeds, the new instance comes up, and the loss only surfaces when someone
  goes looking for a record that was there before the move. The window is the
  dump plus the transfer plus the restore, which on a real database is not
  seconds.

  So: put the old deployment into maintenance mode, or stop its app, and leave
  it that way until DNS points at the new instance. If you would rather rehearse
  first, take a dump while the source is live and restore it to get timings and
  catch version problems — then throw that copy away and repeat with writes
  stopped. A trial run is not a migration, and the only thing that makes it one
  is the source being quiet.

  ```bash
  # on the source, first — stop the app or enable maintenance mode, then look at
  # what is still attached. This lists connections rather than counting active
  # queries on purpose: a Rails pool sits in state 'idle' between requests, so a
  # fully-running app reports zero active and can commit a write a millisecond
  # later. Judge the rows — on a managed provider some are the provider's own.
  psql "$SOURCE_DATABASE_URL" -c \
    "SELECT usename, client_addr, state, backend_start, query
       FROM pg_stat_activity
      WHERE datname = current_database() AND pid <> pg_backend_pid()"

  # one chain, so a failed dump or transfer cannot reach pg_restore --clean
  pg_dump --format=custom "$SOURCE_DATABASE_URL" -f collavre.dump &&
    scp collavre.dump <deploy-user>@<instance-ip>:/tmp/collavre.dump.incoming &&
    ssh <deploy-user>@<instance-ip> \
      'mv /tmp/collavre.dump.incoming /tmp/collavre.dump &&
       sudo -u postgres pg_restore --no-owner --role=<db-user> \
         --clean --if-exists -d "<db-name>" /tmp/collavre.dump &&
       rm /tmp/collavre.dump'
  move_status=$?

  if [ "$move_status" -ne 0 ]; then
    echo "MOVE FAILED — the target may be partly dropped and is not usable yet."
    echo "pg_restore --clean --if-exists is re-runnable: fix the cause and run"
    echo "the whole chain again. Do not point DNS at this instance until it"
    echo "succeeds, and keep the source in maintenance mode until then."
  fi
  ```

  **Why the whole thing is one `&&` chain.** As three separate statements a
  failed `pg_dump` still ran the `scp`, and a failed `scp` still ran the
  `pg_restore --clean` — which drops every object before it discovers it has
  nothing to reload. The `rm` is chained to the restore's success, so a failed
  restore deliberately keeps `/tmp/collavre.dump` to make a retry cheap; three
  statements turn that retained file into the hazard, because the next attempt's
  failed `scp` would restore *it* — an older snapshot — report success, and
  delete the evidence. That is not a failed migration, it is a successful-looking
  one on stale data. The transfer also lands on `.incoming` and is renamed, so an
  interrupted `scp` cannot leave a truncated archive at the path the restore
  reads.

  **Why the restore goes through `sudo -u postgres` and not a connection URL.**
  An earlier revision of this block had you paste `<password>` into
  `postgresql://<db-user>:<password>@127.0.0.1:5432/<db-name>`, which
  contradicts [the password section above](#a-custom-db_password-is-percent-encoded-in-database_url):
  what the state file holds is the *raw* password, and the URL is the one place
  it appears encoded. A `DB_PASSWORD` you chose yourself is then pasted into a
  parser that reads parts of it as syntax. Measured against libpq 14.15:

  ```
  p@ss        could not translate host name "ss@127.0.0.1" to address
  p/ss        could not translate host name "ss" to address
  p%ss        invalid percent-encoded token: "p%ss"
  pa%41ss     connects — as the password "paAss"
  ```

  The first three fail after the `scp`, with the source already in maintenance
  mode. The fourth is the one worth the paragraph: it does not fail at all, it
  authenticates with a different password than the one in the file, so the
  restore works on a host where the app's own role would be rejected — a
  password problem discovered at the next boot rather than here. (`#` and `?`
  pass through libpq unharmed; the wider list in the password section is
  Ruby's `URI.parse`, which is a different parser with a different answer.)

  The local socket needs no password at all, and `postgres` is already the
  superuser the `--clean` needs; `--role=<db-user>` still hands the restored
  objects to the app's role.

- **Coming from SQLite:** `bin/rails db:sqlite_to_postgres[...]`
  (`lib/tasks/db_convert.rake`). Like the fresh install below, this one runs
  *after* `./kamal.sh setup`, because the app container is the only place that
  can reach both ends.

  Running it from your workstation cannot work, and no `DATABASE_URL` fixes
  that. `172.17.0.1` from your machine is your own Docker bridge or nothing,
  and pointing at the instance's public address fails too: this server sets
  `listen_addresses = 'localhost,172.17.0.1'`, so it accepts nothing on the
  public interface, with the ufw rule (Docker range only) as a second layer.

  The only route from outside is an SSH tunnel to the instance's
  `127.0.0.1:5432`. That works, but it streams the whole copy over the tunnel
  and still needs the superuser grant below, so the container is both faster
  and simpler. If you do tunnel, watch `RAILS_ENV`: `config/boot.rb` calls
  `Dotenv.overload(".env.$RAILS_ENV")`, which clobbers only the keys the file
  it loads defines. With `RAILS_ENV=production` exported, `.env.production`
  puts `172.17.0.1` back over the `DATABASE_URL` you passed on the command
  line; without it dotenv reads `.env.development` and your override survives.
  Either way the tunnel does not get you the superuser the copy needs — that
  is what `MIGRATION_RUN_USER` is for, and dotenv never touches it.

  ```bash
  # Stop the source deployment before anything below reads its files, then say
  # so here. `./kamal.sh app stop` further down stops the *new* instance's app,
  # which is holding an empty database — it says nothing about the deployment
  # still serving the SQLite file this recipe copies.
  #
  # This is asked rather than checked because SQLite gives no answer to ask for.
  # The PostgreSQL path above can list pg_stat_activity; here the file is the
  # only witness, and it looks the same whether the writer went away or is
  # simply between requests. So a check would be the reassurance without the
  # fact, and the one thing it must not do is report "quiet" about a source
  # that is still committing.
  source_quiesced=${source_quiesced:-}
  if [ "$source_quiesced" != 1 ]; then
    echo "REFUSING: the source deployment has not been declared stopped."
    echo "  Nothing has been copied, granted or converted."
    echo "  Stop it (or put it in maintenance mode) so no further writes land,"
    echo "  then re-run this block with:"
    echo "    source_quiesced=1"
    echo "  Writes committed to the source after the snapshot below are not"
    echo "  migrated and are not detectable afterwards: the converted database"
    echo "  is complete as of the snapshot and says nothing about what came next."
  else

  ./kamal.sh setup
  ./kamal.sh app stop   # no writes while the schema is dropped and reloaded
  stop_status=$?

  # Snapshot the source rather than copying its file. config/database.yml runs
  # SQLite with `journal_mode: WAL`, so transactions committed since the last
  # checkpoint live in production-primary.sqlite3-wal and are simply absent from
  # the main file — a copy of it alone converts cleanly, reports success, and is
  # missing the most recent rows with nothing to indicate it. VACUUM INTO writes
  # one self-contained file with the WAL folded in and no -wal/-shm companions
  # to forget, and it reads a consistent snapshot rather than a file that may be
  # written mid-transfer.
  #
  # No fallback to `cp` if sqlite3 is missing: that is the bug, not a
  # workaround. Install it on the machine holding the source, or take the
  # snapshot wherever that machine can.
  snap_status=1
  snap_dir=
  if [ "$stop_status" -eq 0 ] && command -v sqlite3 >/dev/null; then
    snap_dir="$(mktemp -d)"
    sqlite3 storage/production-primary.sqlite3 \
      "VACUUM INTO '$snap_dir/production-primary.sqlite3'"
    snap_status=$?
  fi

  # The task reads the SQLite file from inside the container. /rails/storage is
  # the plan42_storage volume, shared by every container of the app, and uid
  # 1000 is the image's `rails` user.
  # Stage under a temporary name and rename into place, so the task can only
  # ever see a complete file. stage_status covers the whole staging step.
  stage_status=1
  if [ "$snap_status" -eq 0 ]; then
    scp "$snap_dir/production-primary.sqlite3" \
        <deploy-user>@<instance-ip>:/tmp/ &&
      ssh <deploy-user>@<instance-ip> \
        'vol="$(docker volume inspect plan42_storage --format "{{.Mountpoint}}")" &&
         sudo install -o 1000 -g 1000 -m 0600 /tmp/production-primary.sqlite3 \
           "$vol/production-primary.sqlite3.incoming" &&
         sudo mv "$vol/production-primary.sqlite3.incoming" \
                 "$vol/production-primary.sqlite3" &&
         rm /tmp/production-primary.sqlite3'
    stage_status=$?
  fi

  # Active Storage blobs. The conversion copies active_storage_blobs *rows*; the
  # files those rows name are not in the database. With no S3 credentials
  # config/environments/production.rb selects `:local`, and config/storage.yml
  # roots that service at Rails.root/storage — the same directory as the SQLite
  # file — so on such a source the blobs are on disk beside it while
  # plan42_storage on the new instance is newly created and empty. Skipped,
  # every attachment 404s after boot from metadata that insists it exists.
  #
  # Harmless when the source used S3: blob keys fan out into two-character
  # directories, the exclude drops the SQLite files and their -wal/-shm
  # companions, and what is left to send is then nothing.
  # Staged to a file rather than piped, so that `tar |ssh` is not what decides
  # whether this worked. A sender that fails part-way through reading still
  # leaves a receiver that succeeds — measured: sender 1, receiver 0, so `$?`
  # is 0 — and a receiver handed a truly empty stream also exits 0. `$?` on the
  # pipeline would therefore report a blob copy that sent nothing as done.
  # `PIPESTATUS` would answer that, but it is bash-only: these blocks get
  # pasted into whatever shell the operator has, and on zsh — macOS's default —
  # `${PIPESTATUS[0]}` is unset (zsh spells it `$pipestatus` and 1-indexes it),
  # the arithmetic fails, and the pre-set 1 below survives to report a copy that
  # in fact succeeded as failed. An `&&`-style chain says the same thing in
  # every shell, and is what the PostgreSQL move above already does with its
  # dump. The cost is a workstation-side file the size of the blob tree, in the
  # directory the snapshot is already using.
  blob_status=1
  if [ "$stage_status" -eq 0 ]; then
    if tar -cf "$snap_dir/blobs.tar" -C storage --exclude='*.sqlite3*' . ; then
      ssh <deploy-user>@<instance-ip> \
        'vol="$(docker volume inspect plan42_storage --format "{{.Mountpoint}}")" &&
         sudo tar -xf - -C "$vol" --no-same-owner &&
         sudo chown -R 1000:1000 "$vol"' < "$snap_dir/blobs.tar"
      blob_status=$?
    else
      # tar's own status, and the transfer never ran.
      blob_status=$?
    fi
  fi

  if [ "$stop_status" -ne 0 ]; then
    echo "STOP FAILED: a container may still be serving and polling this database"
    echo "nothing was staged, granted or converted"
    echo "check './kamal.sh app details' before retrying — do not convert while it runs"
  elif [ "$snap_status" -ne 0 ]; then
    command -v sqlite3 >/dev/null ||
      echo "SNAPSHOT FAILED: no sqlite3 on this machine"
    echo "SNAPSHOT FAILED: nothing was staged, granted or converted"
    echo "the source is untouched — VACUUM INTO only reads it"
    echo "app left stopped on purpose; snapshot before converting"
  elif [ "$stage_status" -ne 0 ]; then
    echo "STAGING FAILED: nothing was granted and nothing was converted"
    echo "the volume still holds whatever was there before — on a retry that is"
    echo "the stale snapshot the previous attempt deliberately kept"
    echo "app left stopped on purpose; re-stage before converting"
  elif [ "$blob_status" -ne 0 ]; then
    echo "BLOB COPY FAILED: nothing was granted and nothing was converted"
    echo "the database was not touched, so this is safe to retry from the top"
    echo "converting now would boot an app whose attachments are all missing"
    echo "app left stopped on purpose; copy the blobs before converting"
  else
    # The copy disables referential integrity, which is superuser-only. The role
    # is double-quoted for the same reason the database is further down this
    # page: DB_USER is an operator setting and the launch script creates whatever
    # it is given through `format('%I')`, so `collavre-app` is a role it makes
    # and `ALTER ROLE collavre-app SUPERUSER` is a syntax error.
    ssh <deploy-user>@<instance-ip> \
      "sudo -u postgres psql -c 'ALTER ROLE \"<db-user>\" SUPERUSER'"
    grant_status=$?

    # Gated on the grant, not run alongside it. MIGRATION_RUN_RESET drops the
    # schema before loading, so a conversion attempted without the superuser it
    # needs trades a working empty database for a broken one and gains nothing.
    copy_status=1
    if [ "$grant_status" -eq 0 ]; then
      ./kamal.sh app exec \
        'bin/rails "db:sqlite_to_postgres[storage/production-primary.sqlite3,production]"' \
        -e MIGRATION_RUN_RESET:true
      copy_status=$?
    fi

    # Take the grant back whether or not the copy worked — a failed cutover is
    # precisely when it would otherwise sit there — and whether or not the grant
    # itself reported success, because a connection that dropped after the ALTER
    # committed leaves the role raised with nothing on this side to say so.
    # NOSUPERUSER against a role that is not one succeeds and changes nothing.
    ssh <deploy-user>@<instance-ip> \
      "sudo -u postgres psql -c 'ALTER ROLE \"<db-user>\" NOSUPERUSER'"
    revoke_status=$?

    # Clean up and boot only if all three worked. Any failure leaves the app down.
    if [ "$grant_status" -eq 0 ] && [ "$copy_status" -eq 0 ] &&
       [ "$revoke_status" -eq 0 ]; then
      ssh <deploy-user>@<instance-ip> \
        'sudo rm "$(docker volume inspect plan42_storage \
           --format "{{.Mountpoint}}")/production-primary.sqlite3"'

      ./kamal.sh app boot   # restart on the data you just loaded
    else
      [ "$grant_status" -eq 0 ] ||
        echo "GRANT FAILED: nothing was converted, and this database is as it was"
      # Only claimed when the grant is known to have taken. Reported the other
      # way round it sends the operator to withdraw a grant that never happened,
      # which is the wrong repair and hides the one that is needed.
      if [ "$revoke_status" -ne 0 ] && [ "$grant_status" -eq 0 ]; then
        echo "REVOKE FAILED: <db-user> is still a superuser — take it back by hand"
      elif [ "$revoke_status" -ne 0 ]; then
        echo "REVOKE FAILED: the grant did not report success either, so read"
        echo "  rolsuper for <db-user> before acting — it may never have been raised"
      fi
      [ "$copy_status" -eq 0 ] || [ "$grant_status" -ne 0 ] ||
        echo "COPY FAILED: this database is now empty or half-loaded"
      echo "app left stopped on purpose; do not boot it until the above is cleared"
    fi
  fi

  # Deliberately not kept for a retry, unlike the PostgreSQL dump above. That
  # one is a transfer that can be repeated; this is a point-in-time snapshot of
  # a database that has since been stopped and may have been restarted, so a
  # second attempt has to take a fresh one rather than convert this.
  [ -z "$snap_dir" ] || rm -rf "$snap_dir"

  fi
  ```

  **Why the snapshot and not the file.** With a writer still attached, the main
  database file and the database are not the same thing:

  ```
  writer holds the connection, two rows committed since the last checkpoint
    production-primary.sqlite3        8192 bytes
    production-primary.sqlite3-wal    4152 bytes
    rows the writer sees                   3
    rows in a copy of the main file        1     <- what the old recipe sent
    rows in VACUUM INTO's snapshot         3
  ```

  Nothing downstream notices the difference. The conversion succeeds, the app
  boots, and the two missing rows are missing — which is why this is the one
  step here that must not be a plain copy. It is also why a source that shut
  down cleanly hides the problem: closing the last connection checkpoints the
  WAL to zero, so the file is complete exactly when you did the thing that made
  it complete, and incomplete on precisely the run where nobody stopped the
  source.

  **Blob files are a second migration, not a detail of this one.** The converter
  says so itself — "only DB metadata rows are copied … leave the storage
  volume/bucket as-is" — which is correct advice for swapping a database under a
  deployment that stays put, and wrong here, because this page is moving hosts.
  The volume it lands on is new.

  **The conversion is gated on staging for a reason that only shows up on a
  retry.** `MIGRATION_RUN_RESET` drops the schema and reloads it from the
  SQLite file *in the volume* — never from the file `scp` just sent. Those are
  the same file only when staging worked. When it did not, the volume still
  holds the previous attempt's snapshot, which the failure path above
  deliberately keeps so a retry does not need another full copy over the wire.
  Ungated, a failed `scp` therefore converts from that stale snapshot, reports
  success, deletes it, and boots the app on older data — a silent rollback of
  production, and the loudest signal is a timestamp nobody is looking at. The
  rename makes the staging step atomic as well, so a copy interrupted midway
  leaves the previous file in place rather than a truncated database.

  The grant is not optional. The launch script creates the role with
  `CREATE ROLE ... LOGIN` and nothing else, and the copy runs
  `ALTER TABLE ... DISABLE TRIGGER ALL`, which needs a superuser — owning the
  table is not enough. The task checks this up front and aborts with
  instructions rather than dying halfway through with a `ForeignKeyViolation`,
  so a forgotten grant costs you a message, not a half-loaded database. The
  other route the task offers, `MIGRATION_RUN_USER=postgres`, would mean giving
  the superuser role a password that every container on the host could then
  authenticate with — which is why the grant lands on the app role instead.

  **That is also why the revoke is not conditional on the copy succeeding.**
  `collavre_user` is the role in `DATABASE_URL`, so it is what every app
  container authenticates as. Leaving it a superuser turns any SQL injection
  into `COPY ... FROM PROGRAM` — arbitrary commands as the `postgres` user on
  the host — and a failed cutover is exactly the moment you are least likely to
  remember a line further down the page. The window is not merely the length of
  the copy: troubleshooting a failed cutover usually means booting the app to
  look at it, and the container comes up holding superuser credentials.

  Revoking on failure costs nothing, because the same up-front check makes the
  retry safe. Re-run without re-granting and the task aborts before it touches
  the database, telling you what is missing. So the recovery is: re-grant,
  re-run, and only then `app boot`.

  **Neither failure may reach `app boot`, which is why the tail of the block is
  a conditional.** `MIGRATION_RUN_RESET` drops the schema before it loads
  anything, so a copy that dies partway through leaves this database empty or
  half-populated — booting then serves exactly that. The `sudo rm` is as bad in
  its own way: it destroys the staged SQLite file the task reads from, so a
  retry needs another full `scp` of production rather than just the re-grant
  and re-run above. A failed *revoke* must not boot either, for the reason in
  the previous paragraph — the container would come up holding superuser
  credentials, which is the exposure the revoke exists to close. So cleanup and
  boot are gated on both statuses and the app stays stopped otherwise. `exit`
  would be the wrong tool: these lines get pasted into an interactive shell,
  where it closes the session instead of stopping the recipe.

  `MIGRATION_RUN_RESET=true` matters because `setup` has already run the
  migration replay this section opened by distrusting. The task's schema load
  uses `force: :cascade`, which drops only the tables `db/schema.rb` still
  knows about, so anything the replay left behind that the schema has since
  dropped would survive into the migrated database. `MIGRATION_RUN_RESET`
  does `DROP SCHEMA public CASCADE` first — a real clean slate, superuser-only,
  which the grant above already covers. It trails the command for the same
  Thor-hash reason as the fresh-install recipe below.

  No `DISABLE_DATABASE_ENVIRONMENT_CHECK` here, unlike the fresh install below.
  The task calls `DatabaseTasks.load_schema` directly instead of the
  `db:schema:load` task, so `check_protected_environments` never runs. It also
  stamps `schema_migrations` for the engine migrations as well as the primary
  ones, so the next boot's `db:migrate` is a no-op.

- **Genuinely fresh install:** there is nothing to restore, so this one runs
  *after* `./kamal.sh setup` rather than before it — `app exec` needs the
  `kamal` network and the uploaded env file, and both are created by the same
  boot that runs the migration replay. Deploy first, then overwrite whatever
  the replay produced with the canonical schema:

  ```bash
  ./kamal.sh setup
  ./kamal.sh app stop   # no reads or writes while the schema is dropped and reloaded
  stop_status=$?

  ADMIN_PASSWORD="$(openssl rand -base64 18)"   # not in shell history; print it below
  load_status=1
  if [ "$stop_status" -eq 0 ]; then
    ./kamal.sh app exec 'bin/rails db:schema:load:primary db:seed' \
      -e DISABLE_DATABASE_ENVIRONMENT_CHECK:1 \
         DEFAULT_USER_EMAIL:you@example.com \
         DEFAULT_USER_PASSWORD:"$ADMIN_PASSWORD"
    load_status=$?
  fi

  if [ "$stop_status" -ne 0 ]; then
    echo "STOP FAILED: a container may still be serving and polling this database"
    echo "nothing was loaded; the schema is whatever the migration replay produced"
    echo "check './kamal.sh app details' before retrying — do not load while it runs"
  elif [ "$load_status" -eq 0 ]; then
    echo "$ADMIN_PASSWORD"   # sign in, then change it
    ./kamal.sh app boot      # restart on the schema you just loaded
  else
    echo "LOAD FAILED: the schema is partial and there may be no admin user"
    echo "app left stopped on purpose; re-run the load before booting it"
  fi
  ```

  **The boot is gated on the load for the same reason the cutover above is.**
  These lines are pasted into an interactive shell with no `set -e`, so an
  unconditional `app boot` runs even when the load returned nonzero.
  `db:schema:load` drops and recreates every table, so a failure partway leaves
  a partial schema — and `db:seed` is what creates the first admin, so a load
  that got far enough to reset the database but not far enough to seed it boots
  a production app with no way to sign in and no owner on any record. Neither
  state is one to serve while you work out what happened. Re-run the same
  `app exec` once it is fixed; it resets the schema again, so a retry is clean
  rather than additive.

  **`app stop` is not politeness.** `setup` ends by booting the app, so by the
  time you run the load a container is already talking to this database — and
  not only when a browser reaches it. `config/deploy.yml` defaults
  `SOLID_QUEUE_IN_PUMA` to `true`, so the web container runs the Solid Queue
  supervisor in-process and polls for work on a timer whether or not anyone has
  found the host yet. Those tables are in the schema being loaded: `db/schema.rb`
  declares 13 `solid_*` tables `force: :cascade`, and `cache`, `queue` and
  `cable` all fall back to `DATABASE_URL` unless you set their own
  ([§3](#3-how-postgresql-is-reachable)), so the load drops the queue tables out
  from under a live poller. `DROP TABLE` needs an `ACCESS EXCLUSIVE` lock and
  the poller is querying the same tables, so the two contend in both directions:
  the load blocks behind a poll that is mid-transaction, and a poll that arrives
  while a table is gone fails against a relation that does not exist yet. How
  that surfaces depends on where the timer lands — a load that pauses, errors in
  `./kamal.sh logs`, or nothing visible at all on a lucky run. Which is the
  argument for stopping rather than for timing it well. It also settles what
  happens to anything written between `setup` and the load: the schema is
  replaced either way, so there is no point letting a request believe otherwise.

  **Which is why the load is gated on the stop, not merely preceded by it.**
  Everything in the paragraph above is an argument about a container that is
  still running — so it applies unchanged when `app stop` is the thing that
  failed. Unreachable host, a docker daemon that will not answer, a role that
  cannot stop the container: the command returns nonzero, the container keeps
  serving and polling, and with no `set -e` the next line drops every table
  underneath it. Adding the `app stop` fixed the case where nobody ran it;
  gating on it fixes the case where it ran and did not work. `kamal app stop`
  is idempotent, so the recovery is to fix whatever broke it, run it again, and
  carry on — nothing was loaded.

  **Supply the admin credentials.** `db/seeds.rb` falls back to
  `admin@example.com` / `password123` and marks that user `system_admin`. That
  is a convenience in development and a published login on a host that answers
  on 443, so the seed *refuses* the fallback under `RAILS_ENV=production` and
  tells you what to pass — a fresh install with no `DEFAULT_USER_PASSWORD` ends
  with no admin rather than a known one. The engine seeds still run either way;
  they mint their own credentials with `SecureRandom`.

  These two are one-shot inputs to this command, not deployment settings.
  Keeping them out of `.env.production` and `config/deploy.yml` is deliberate:
  a `DEFAULT_USER_PASSWORD` that ships with every deploy would resurrect the
  same standing credential this guard exists to remove.

  **`:primary` is load-bearing.** `production:` in `config/database.yml` names
  four configurations — primary, cache, queue, cable — and the plain
  `db:schema:load` walks every one of them. It loads `db/schema.rb` for the
  primary, then looks for `db/cache_schema.rb`, which does not exist and never
  will: all four point at one database and the Solid tables come from a primary
  migration (see [§3](#3-how-postgresql-is-reachable)). So the run stamps the
  schema correctly and *then* aborts with

  ```
  db/cache_schema.rb doesn't exist yet. Run `bin/rails db:migrate` to create it, then try again.
  ```

  and exit status 1. `db:seed` never runs, so a fresh install ends with the
  right schema, **no admin user**, and the on-screen advice being the migration
  replay this section exists to avoid. `db:schema:load:primary` is the same
  work minus the walk — `assume_migrated_upto_version` behaves identically, and
  the task carries the same `check_protected_environments` prerequisite, so the
  flag below is still required.

  `db/schema.rb` declares every table `force: :cascade`, so the load replaces
  the replayed tables instead of colliding with them, and it stamps
  `schema_migrations` up to the schema version — the next boot's `db:migrate`
  is a no-op.

  That covers the engine migrations too, which is worth stating because the
  SQLite task above has to stamp them by hand. Both `db:schema:load` and its
  `:primary` variant run after `db:load_config`, and that is where Rails widens
  `ActiveRecord::Migrator.migrations_paths` from `["db/migrate"]` (7 files) to
  every path the engines append (184). `db:sqlite_to_postgres` depends on
  `:environment` alone, so it never gets that widening: its schema load stamps
  8 versions — the 7 primary migrations plus the schema's own version, which
  `assume_migrated_upto_version` inserts whether or not it can see the file
  behind it — and it must stamp the remaining 176 itself.

  `DISABLE_DATABASE_ENVIRONMENT_CHECK` is not optional here. The load task
  runs `check_protected_environments` first, which aborts with
  `ActiveRecord::ProtectedEnvironmentError` once the database records
  `production` in `ar_internal_metadata` — which is exactly what the replay in
  the preceding `setup` just wrote. Note the flag *trails* the command: `-e`
  takes a Thor hash and greedily consumes every following argument containing a
  colon, so putting it first would swallow
  `bin/rails db:schema:load:primary db:seed` into the hash and leave kamal with
  no command to run.

  This still works when the replay *fails* and `setup` dies at `app boot`: the
  env file and the network are uploaded before the container is started, and
  `app exec` runs a **new** container whose command is
  `bin/rails db:schema:load:primary`,
  which the entrypoint does not migrate for (it only migrates the
  `./bin/rails server` command line). Run the `app exec` above and then
  `./kamal.sh deploy`. The `app stop` is a no-op on this path rather than a
  step to skip — there is no container to stop, and kamal does not treat that
  as an error.

## 6. Backups

`collavre-pg-backup.timer` runs nightly at 03:30 (instance timezone, Asia/Seoul
by default) and writes custom-format dumps to `/var/backups/collavre`, keeping 7
days. With `BACKUP_S3_URI` set and AWS credentials in `/root/.aws/credentials`
(Lightsail has no IAM instance role) each dump is also copied to S3 — the launch
script installs the AWS CLI when that variable is set. If the upload cannot
happen the local dump is still written and kept, but the unit exits non-zero, so
a broken off-instance backup shows up as a failed
`collavre-pg-backup.service` in `systemctl list-units --failed` instead of
looking healthy.

```bash
sudo /usr/local/bin/collavre-pg-backup          # run one now
systemctl list-timers collavre-pg-backup.timer  # check schedule
journalctl -u collavre-pg-backup.service        # check last run

# restore — stop the app FIRST, from your workstation:
#   ./kamal.sh app stop
# then, on the instance. The stop happens on a different machine, so rather than
# trust that it ran, shut the database itself to the app for the duration.
# CONNECTION LIMIT 0 does not apply to superusers, so pg_restore below still
# connects; a container that survived the stop, or restarts mid-restore, cannot.

# Which database, and which role, before anything is asked about either. Both
# are the host's answer rather than this page's: `DB_NAME` is overridable at
# provisioning time and the rename procedure above makes it the operator's, so
# a literal here would shut, count, terminate and restore a database that is
# not the one holding the data — and every one of those steps would report
# success against the wrong name or fail for a reason that reads like a
# cluster problem.
# `${app_db:-...}` rather than a plain assignment, so the recovery the refusal
# below prints is one the block actually honours: setting app_db in the shell
# and pasting again has to survive this line, or the instruction is a dead end.
app_db=${app_db:-$(sudo cat /var/lib/collavre/db_name 2>/dev/null)}
app_role=$(sudo cat /var/lib/collavre/db_user 2>/dev/null)

# Then whether that last clause is true on THIS host. The exemption that lets
# pg_restore in is role-wide, so it lets the app in too whenever the app's own
# role is a superuser — and `DB_USER=postgres` on a first run is legal (see
# "Changing DB_USER on a re-run"). Refusing before the ALTER rather than after
# it, so a refusal leaves the connection limit exactly as the operator had it.
app_super=$(sudo -u postgres psql -qtAd postgres -c \
  "SELECT rolsuper FROM pg_roles WHERE rolname = '$app_role'" 2>/dev/null)

# And what the limit was before this block touched it, read here because after
# the ALTER below it is 0 and the previous value is gone. `-1` is only the
# default; an operator who capped this database has that cap in `datconnlimit`
# and nowhere else, so re-opening to a literal `-1` would not restore the
# database to what it was, it would silently lift a limit — on every successful
# restore, and on the idle refusal too, which touches nothing else at all.
#
# `${prior_limit:-...}` rather than a plain assignment, and the reason is the
# retry the failure path below invites. A restore that fails leaves the database
# at 0 on purpose; pasting the block again then re-reads `datconnlimit` and gets
# that 0 — this block's own leftover — as "what it was before". The successful
# second attempt puts back 0, the original cap is gone with nothing left that
# knows it, and the message printed is the one that says the 0 was already
# there. So the value has to survive the attempt that failed, and it is unset at
# the bottom once it has been put back, so a later unrelated restore in the same
# shell reads the cluster afresh rather than inheriting this one's answer.
prior_limit=${prior_limit:-$(sudo -u postgres psql -qtAd postgres -c \
  "SELECT datconnlimit FROM pg_database WHERE datname = '$app_db'" 2>/dev/null)}

# "This block has not shut anything yet", set before the two refusals below so
# that it is answered on every path rather than only on the ones that reach the
# ALTER. Non-zero is the safe value: the re-open is gated on it, and a refusal
# that never touched the limit must not lift the operator's own cap.
shut_applied=1
if [ -z "$app_db" ]; then
  echo "REFUSING: cannot tell which database to restore."
  echo "  /var/lib/collavre/db_name is missing or unreadable. That file is"
  echo "  written by script/lightsail_launch.sh once the database exists, so an"
  echo "  empty answer means this host was provisioned by a revision that"
  echo "  predates it, or the read failed. Falling back to the default name is"
  echo "  the one thing this block must not do: on a host that used DB_NAME, or"
  echo "  the rename procedure, the default names a database that either does"
  echo "  not exist or is not the live one."
  echo "Nothing was changed. Confirm the name, then set it for this block:"
  echo "  sudo -u postgres psql -qtAd postgres -c \\"
  echo "    \"SELECT datname FROM pg_database WHERE NOT datistemplate\""
  echo "  app_db=<the database>   # then re-run this block"
  restore_status=3
elif [ "$app_super" != f ]; then
  echo "REFUSING: cannot shut this database to the app."
  echo "  DB_USER is '$app_role' and its rolsuper is '$app_super' — anything but"
  echo "  'f' means the gate below cannot tell your app apart from pg_restore,"
  echo "  because CONNECTION LIMIT does not apply to superusers. An empty value"
  echo "  means the question could not be answered (no /var/lib/collavre/db_user,"
  echo "  no such role, cluster unreachable), which is not the same as 'no'."
  echo "Nothing was changed. On your workstation, confirm the app is really gone:"
  echo "  ./kamal.sh app details          # no running container"
  echo "then run the rest of this block by hand. There is no in-database way to"
  echo "exclude a superuser app while admitting pg_restore: if DB_USER really is"
  echo "'postgres' they are the same role, and ALTER ROLE postgres NOLOGIN locks"
  echo "out the restore along with the app."
  restore_status=3
else

# Double-quoted, because $app_db came out of a state file rather than out of
# this page: DB_NAME is an operator setting, and the launch script creates
# whatever it is given through `format('%I')`. `collavre-prod` is a legal
# database name there and a syntax error here unquoted — PostgreSQL reads the
# hyphen as subtraction. Quoting is right for an ordinary name too.
sudo -u postgres psql -qd postgres -c \
  "ALTER DATABASE \"$app_db\" CONNECTION LIMIT 0"
# Kept separately from the read-back below, because they answer different
# questions and only one of them decides who owns the limit afterwards. The
# read-back says whether the door is shut; this says whether *this block* is
# the one that shut it. They disagree exactly when the ALTER committed and the
# read-back could not be answered — the cluster restarted in between, the
# connection dropped — and that is the case where "nothing was changed" is
# false and the re-open below is the only thing that will unlock the app.
shut_applied=$?

# Read the limit back rather than trusting that the line above ran. These
# blocks are pasted into an interactive shell with no `set -e`, so a failed
# ALTER just scrolls past — and if nothing happens to be attached a moment
# later, the count below reads 0 and the restore starts against a database
# that was never shut. `datconnlimit` is the state itself, so it cannot say
# "closed" about a door that is open.
shut=$(sudo -u postgres psql -qtAd postgres -c \
  "SELECT datconnlimit FROM pg_database WHERE datname = '$app_db'")

if [ "$shut" != 0 ]; then
  echo "REFUSING: could not shut $app_db to the app."
  echo "  its connection limit is '$shut', not 0"
  if [ "$shut_applied" -eq 0 ]; then
    # The ALTER reported success and the read-back disagrees, so the value
    # above is not evidence the limit is unchanged — it is the absence of an
    # answer. Saying "the ALTER did not take" here would be a guess in the one
    # direction that leaves the app locked out, so the re-open below runs.
    echo "  but the ALTER above reported success, so the limit may in fact be"
    echo "  0 and this block cannot tell. Putting it back below rather than"
    echo "  leaving the app to meet 'too many connections' at boot."
  else
    echo "  and the ALTER above did not take"
    echo "  (wrong database name? not superuser? cluster gone?)"
  fi
  echo "nothing was dropped; fix that and re-run this block"
  # Its own status, not the refusal below: this block never dropped anything.
  # Whether it also has a limit to put back is a separate question, answered by
  # $shut_applied at the re-open — on the path where the ALTER never ran, the
  # limit is still the operator's and lifting it would be this block changing
  # something it had refused to touch.
  restore_status=3
else

sudo -u postgres psql -qtAd postgres -c \
  "SELECT count(pg_terminate_backend(pid)) FROM pg_stat_activity
    WHERE datname = '$app_db' AND pid <> pg_backend_pid()"

# Now check, with the door confirmed shut — a point-in-time count taken before
# this would only have said the app happened to be between connections.
live=$(sudo -u postgres psql -qtA -d postgres -c \
  "SELECT count(*) FROM pg_stat_activity
    WHERE datname = '$app_db' AND pid <> pg_backend_pid()")

# A string comparison, not -ne: if the query above failed, $live is empty or an
# error message, and `[ "$live" -ne 0 ]` would error and be read as false —
# a gate that opens when the check breaks. Anything that is not exactly "0"
# stops here.
if [ "$live" != 0 ]; then
  echo "REFUSING: $app_db is not confirmed idle (check returned: '$live')."
  sudo -u postgres psql -d postgres -c \
    "SELECT usename, client_addr, state, query
       FROM pg_stat_activity WHERE datname = '$app_db'"
  echo "run './kamal.sh app stop' on your workstation and check it succeeded"
  echo "nothing was dropped; re-run this block once the app is down"
  restore_status=2
else
  # `--no-owner --role=$app_role`, the same pair the import recipe above uses,
  # and for the reason a recovery restore makes sharper: the archive carries the
  # ownership the database had when it was dumped. A dump taken before a
  # supported DB_USER rotation names the previous role, so replaying it hands
  # every table back to that role while DATABASE_URL still names $app_role.
  # Measured on a real cluster: the restore exits 0, and the app's own role then
  # gets "permission denied for table creatives" on SELECT and INSERT. A
  # recovery that reports success and leaves the app locked out of its own data
  # is the worst shape this block can produce.
  #
  # $app_role is safe to name here because the two refusals above have already
  # answered for it: an empty one, or one that is a superuser, never reaches
  # this line.
  #
  # One case this makes louder rather than quieter, and it is the right
  # direction. `--role` drops the superuser privileges the connection had, so if
  # the objects *currently* in the database belong to some third role, the
  # `--clean` DROPs fail with "must be owner of table" and pg_restore exits
  # non-zero — measured, and the database is left exactly as it was rather than
  # half-replaced. Without `--role` that host restores "successfully" into the
  # same locked-out app. If you see that error, the objects are owned by a role
  # nothing names; move them first and run this block again:
  #   sudo -u postgres psql -qtAd "$app_db" -c \
  #     "SELECT DISTINCT tableowner FROM pg_tables WHERE schemaname = 'public'"
  #   sudo -u postgres psql -qd "$app_db" -c \
  #     'REASSIGN OWNED BY "<that role>" TO "'"$app_role"'"'
  sudo -u postgres pg_restore --clean --if-exists --no-owner --role="$app_role" \
    -d "$app_db" "/var/backups/collavre/$app_db-YYYYmmdd-HHMMSS.dump"
  restore_status=$?
fi

fi

fi

# Re-open on the two paths where this block shut the door and the database is
# whole — a restore that succeeded, and a refusal that touched nothing. A
# database left at CONNECTION LIMIT 0 refuses the app at boot with "too many
# connections", which reads like a pool problem and not like a step this block
# forgot to undo, so it must not be left shut by accident. On the failure path
# it is left shut on purpose; on status 3 it was never shut to begin with.
#
# Back to what it was, not to -1. The one case where that cannot be honoured is
# a $prior_limit that is not a number — the read above failed while the ALTER
# still took — and there -1 is the lesser wrong: leaving the door shut for want
# of a value produces exactly the misdirected "too many connections" this
# undoes. It is said out loud rather than assumed, because the operator is the
# only one who knows what the cap was.
reopen_limit=$prior_limit
if ! printf '%s' "$prior_limit" | grep -qE '^-?[0-9]+$'; then
  reopen_limit=-1
  # Only where it changes what happens next — which is "is this block about to
  # re-open?", not "which status is it". On the status-3 paths that never ran
  # the ALTER the previous limit is still in force and saying it could not be
  # read would be a warning about nothing; on the status-3 path where the ALTER
  # took and the read-back did not answer, the re-open runs and the operator is
  # about to get -1 instead of their cap, which is the case the note is for.
  if [ "$restore_status" -ne 3 ] || [ "$shut_applied" -eq 0 ]; then
    echo "NOTE: could not read $app_db's previous connection limit ('$prior_limit')."
    echo "  Re-opening to -1, the default. If you had capped this database, set"
    echo "  the cap again by hand once this block finishes."
  fi
fi
reopen_status=0
reopen_ran=0
# The third clause is the unconfirmed close. Status 3 otherwise means "refused
# before touching anything", and re-opening there would lift a cap this block
# never applied — but when the ALTER itself reported success the limit is this
# block's to put back whether or not the read-back could confirm it, and
# putting back the value it found is a no-op in the case where the ALTER turned
# out not to have taken. Leaving it out is not symmetrical with that: it leaves
# a database at CONNECTION LIMIT 0 under a message that says nothing changed.
if [ "$restore_status" -eq 0 ] || [ "$restore_status" -eq 2 ] ||
   { [ "$restore_status" -eq 3 ] && [ "$shut_applied" -eq 0 ]; }; then
  sudo -u postgres psql -qd postgres -c \
    "ALTER DATABASE \"$app_db\" CONNECTION LIMIT $reopen_limit"
  reopen_status=$?
  reopen_ran=1
fi

# The re-open is checked, not assumed. It is its own connection to the cluster
# and fails on its own terms — the cluster restarted, the role lost superuser,
# the database name is wrong — and `restore_status` says nothing about it. Left
# unchecked, the success path prints "boot the app" over a database still at
# CONNECTION LIMIT 0, and what the operator then meets is "too many
# connections" at boot: the same misdirected error the block shuts the door to
# avoid, arrived at from the step that was supposed to undo it. Reported before
# the restore's own outcome, because it is the one thing here that stands
# between a good restore and an app that cannot reach it.
if [ "$reopen_status" -ne 0 ]; then
  echo "RE-OPEN FAILED: $app_db is still at 'CONNECTION LIMIT 0'."
  if [ "$restore_status" -eq 0 ]; then
    echo "  The restore finished — the data is not what failed. Do not re-run"
    echo "  this block to clear it: pg_restore --clean would drop a good restore"
    echo "  to repair a connection limit."
  else
    echo "  Nothing was dropped — this block refused above — but the limit it"
    echo "  applied to shut the door is still in force."
  fi
  echo "  The app will be refused at boot with 'too many connections', which"
  echo "  will read like a pool problem. Do not boot it until this succeeds:"
  echo "  sudo -u postgres psql -qd postgres -c \\"
  # Single-quoted for the shell so the identifier's own double quotes survive
  # being pasted — the recovery this prints has to be runnable as printed.
  echo "    'ALTER DATABASE \"$app_db\" CONNECTION LIMIT $reopen_limit'"
  echo "  Confirm with:"
  echo "  sudo -u postgres psql -qtAd postgres -c \\"
  echo "    \"SELECT datconnlimit FROM pg_database WHERE datname = '$app_db'\""
elif [ "$restore_status" -eq 0 ]; then
  # Putting the limit back faithfully has one consequence worth naming: if it
  # was already 0, the door this block opens is the one the operator closed, and
  # "boot the app" would be an instruction to meet "too many connections". That
  # is their configuration rather than this block's leftover, so it is reported
  # rather than overridden.
  if [ "$reopen_limit" = 0 ]; then
    echo "restored, and $app_db is back at 'CONNECTION LIMIT 0' — the limit it"
    echo "  carried when this block read it. That is your own cap unless a"
    echo "  previous attempt failed and you re-ran this block from a fresh"
    echo "  shell, in which case it is that attempt's leftover and the original"
    echo "  value is not recorded anywhere. Either way the app is refused at"
    echo "  boot until you lift it:"
    echo "  sudo -u postgres psql -qd postgres -c \\"
    echo "    'ALTER DATABASE \"$app_db\" CONNECTION LIMIT -1'"
  else
    echo "restored; boot the app from your workstation: ./kamal.sh app boot"
  fi
elif [ "$restore_status" -eq 2 ] || [ "$restore_status" -eq 3 ]; then
  # Refused without dropping anything, and whatever limit was applied has been
  # put back above — see the refusal's own message, which is the one that knows
  # which of these two it was.
  :
else
  echo "RESTORE FAILED: objects may be dropped or only partly reloaded."
  echo "$app_db is LEFT AT 'CONNECTION LIMIT 0' deliberately: it is"
  echo "  now half-replaced, and a container that survived the stop must not"
  echo "  reconnect and write into it. pg_restore is a superuser and is exempt,"
  echo "  so fix the cause and run this block again."
  echo "Its limit before this block ran was '$reopen_limit'. Re-running in THIS"
  echo "  shell keeps that value; re-running in a new one would read the 0 above"
  echo "  as the previous limit and put that back on success. If you open a new"
  echo "  shell, carry it over first:"
  echo "  prior_limit=$reopen_limit    # then paste this block again"
  echo "If instead you are abandoning the restore, re-open it by hand with:"
  echo "  sudo -u postgres psql -qd postgres -c \\"
  echo "    'ALTER DATABASE \"$app_db\" CONNECTION LIMIT $reopen_limit'"
fi

# The saved value is released once it has been put back, and only then. Kept
# across the failure path above — that is the whole point of saving it — but a
# value left set outliving a completed restore is the same defect in the other
# direction: a second, unrelated restore pasted into the same shell would open
# its database to the first one's limit instead of reading the cluster.
# `reopen_ran`, set where the ALTER is issued, rather than re-testing the three
# clauses that decide whether it is issued: a second spelling of that condition
# is one that drifts, and on the failure path it would drift in the direction
# that throws the value away — `reopen_status` is still its initial 0 there,
# because nothing ran to change it.
#
# And on the paths that leave the door shut, the value is pinned to the one the
# message above printed. `${prior_limit:-...}` treats an empty value as unset,
# so a prior read that failed while the ALTER still took would be re-read on the
# retry — off a database this block has since shut, which answers 0. The retry
# then "restores" 0 and reports it as the cap the database carried, while the
# message that invited the retry had promised '-1'. Pinning it here keeps that
# promise; a refusal that never shut anything is deliberately not pinned, since
# there the cluster still holds the operator's own cap and re-reading it on the
# retry is the right answer.
if [ "$reopen_ran" -eq 1 ] && [ "$reopen_status" -eq 0 ]; then
  unset prior_limit
elif [ "$shut_applied" -eq 0 ]; then
  prior_limit=$reopen_limit
fi
```

**`pg_restore --clean` drops every object before recreating it**, so this is the
same hazard as the schema load in [§5](#5-first-deploy) and wants the same
treatment: `app stop` first, `app boot` only after it succeeds. A live Puma and
the in-process Solid Queue poller (`SOLID_QUEUE_IN_PUMA` defaults to `true`)
would otherwise be querying tables as they are dropped — requests failing
against relations that no longer exist, and, worse, writes landing in the window
between a table being recreated and its rows being copied back in. Those writes
are not rolled back by anything; they are simply overwritten or left orphaned
depending on when they arrive, and a restore that reports success is what you
are left looking at.

Unlike the recipes in §5, the two halves run in different places — `app stop`
and `app boot` from your workstation where `kamal.sh` and the env file live, the
`pg_restore` on the instance — so this is deliberately three steps rather than
one block. `pg_restore --clean --if-exists` is re-runnable, so a failed restore
is fixed by fixing the cause and running it again, not by booting to look
around.

**Which is also why the block shuts the database rather than only counting
connections.** A count is true for the instant it runs. If `app stop` did not
take and the surviving container happens to be between connections — restarting,
reconnecting after a dropped socket, or simply idle — the count is `0` and the
restore starts anyway, with Puma free to reconnect while objects are being
dropped. Since the stop happens on another machine, there is no local status to
gate on, so the gate has to be a state rather than an observation:
`CONNECTION LIMIT 0` holds for the whole restore, and superusers are exempt from
it, which is why `pg_restore` still connects while the app cannot. The
`pg_terminate_backend` clears whatever was already attached, and the check
afterwards then means something — it is asking whether anything got past a
closed door, not whether the app happened to be quiet.

**That exemption is role-wide, so the block refuses a superuser `DB_USER`
before it shuts anything.** It is the same property working in both directions:
on `postgres:17` with `datconnlimit` at `0`, an ordinary role is turned away
with `FATAL: too many connections for database "collavre_production"`, and
`postgres` connects and writes a row. `DB_USER=postgres` on a first run is
legal, so this is a host the script produces rather than a misconfiguration —
and on it the door would be shut against nobody while the surrounding prose,
and the `live` count that follows, both read as though it were shut. There is
no in-database way out: on that host the app's role and `pg_restore`'s role are
the same role, so nothing distinguishes them, and `ALTER ROLE postgres NOLOGIN`
locks out the restore along with the app. So the block stops and hands the
operator the only check that does discriminate, which is on the workstation,
and it stops *before* the `ALTER` so a refusal leaves the connection limit as
it found it. The condition is `!= f` rather than `= t`: an unanswerable
question — no state file, no such role, cluster unreachable — has to read as
the unsafe answer, the same rule as the `live` comparison below it.

**A failed restore keeps the door shut.** `pg_restore --clean` drops before it
reloads, so a run that dies partway leaves the database genuinely half-replaced
— on a 20,000-row pair of tables, truncating the dump to 70% gives back
`posts` with every row and `users` with none. Re-opening at that point is worse
than never having shut it: the surviving container reconnects to a database
that looks like it has been emptied, and a signup lands in it and returns an id.
The recipe's own advice is to fix the cause and run the block again, and the
retry drops that row along with everything else, so the write is gone with no
error anywhere — the failure is announced to the operator and the data loss is
not. The limit therefore stays at `0` until a restore succeeds. Nothing is
waiting on it: `pg_restore` is a superuser and exempt, so the retry needs no
extra step, and the message says which command lifts it if the restore is being
abandoned instead.

Local dumps die with the instance. Enable `BACKUP_S3_URI`, or take a Lightsail
snapshot schedule, before this host holds real customer data.

### `BACKUP_S3_URI` does not cover uploaded files

The nightly job dumps PostgreSQL and nothing else. Whether that is the whole of
your data depends on how Active Storage resolved at boot: `production.rb` picks
`:amazon` only when a **complete** S3 credential pair is available — from
`AWS_S3_ACCESS_KEY_ID` / `AWS_S3_SECRET_ACCESS_KEY`, or from the pair saved in
admin settings — and falls back to `:local` otherwise. There is no warning when
it falls back; the app runs identically either way.

On `:local`, every uploaded file and attachment is written inside the container
to `/rails/storage`, which `config/deploy.yml` maps to the named Docker volume
`plan42_storage`. That volume outlives redeploys, so nothing looks wrong day to
day — but it lives on the instance's disk, is not in the dump, and is not
touched by the backup script. Restoring `BACKUP_S3_URI` onto a fresh instance
gives you a database whose `active_storage_blobs` rows all point at files that
no longer exist.

Pick one before going live:

- **Configure app S3** (`AWS_S3_*` in `.env.production`, or admin settings), so
  blobs are off-instance to begin with and the dump really is the whole backup.
- **Or add a Lightsail snapshot schedule**, which captures the disk — volume
  included — and covers both halves at once.

A snapshot schedule is worth having regardless: it is the only thing that
restores the host itself.

## 7. TLS

`config/deploy.yml` currently sets `proxy.ssl: false` with `app_port: 80`,
i.e. TLS is terminated in front of the app (Cloudflare). Keep that, or let
kamal-proxy get a Let's Encrypt certificate itself:

```yaml
proxy:
  ssl: true
  host: collavre.example.com
  app_port: 80
```

That requires the DNS A record to point at the instance and port 443 open in
both the Lightsail firewall and ufw (the script already allows 443).

## 8. Troubleshooting

| Symptom | Check |
| --- | --- |
| Launch script did nothing | `/var/log/collavre-launch.log`, `/var/log/cloud-init-output.log` |
| `kamal` can't SSH | `sudo cat /home/collavre/.ssh/authorized_keys` — empty means no `SSH_PUBLIC_KEY` and no key to copy |
| `kamal` SSH works, Docker denied | Reconnect: `docker` group membership needs a new session |
| `sudo: a password is required` | The deploy user has no password, so `%sudo` alone cannot authenticate it. `sudo ls /etc/sudoers.d/90-collavre-*` from the `ubuntu` account — missing means the host predates that grant; re-run the launch script with `FORCE=1` **and every setting in `/var/lib/collavre/launch.env`**, or the re-run is refused |
| App: `could not connect to server` | `sudo ss -lntp \| grep 5432` should show `127.0.0.1:5432` **and** `172.17.0.1:5432` |
| App: `password authentication failed` | `sudo cat /var/lib/collavre/db_password` vs `DATABASE_URL` — the URL holds the [percent-encoded](#a-custom-db_password-is-percent-encoded-in-database_url) form |
| PostgreSQL won't start after reboot | `sysctl net.ipv4.ip_nonlocal_bind` must be `1`; `journalctl -u postgresql@17-main` |
| `relation "solid_queue_jobs" does not exist` | Schema never loaded — see §5 |
| Disk filling up | `docker system prune -af`, `/var/backups/collavre`, `/var/log` |

## Alternative: PostgreSQL as a Kamal accessory

If you would rather have Kamal own the database container, drop steps 5–6 of the
launch script and add to `config/deploy.yml`:

```yaml
accessories:
  db:
    image: postgres:17
    host: <instance ip>
    port: "127.0.0.1:5432:5432"
    env:
      clear:
        POSTGRES_USER: collavre_user
        POSTGRES_DB: collavre_production
      secret:
        - POSTGRES_PASSWORD
    directories:
      - data:/var/lib/postgresql/data
```

`DATABASE_URL` then points at `collavre-db:5432` over the `kamal` network. It is
one less thing to install, but the database lifecycle becomes tied to Kamal
(`kamal remove` takes the volume with it), backups need a container-aware
wrapper, and PostgreSQL upgrades stop being `apt` upgrades. The launch script
takes the host-native path for those reasons.

## References

- [Kamal configuration](https://kamal-deploy.org/docs/configuration/)
- [deploy_to_ec2.md](deploy_to_ec2.md) — the earlier EC2 notes
