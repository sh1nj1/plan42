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
>   remote: ssh://collavre@<instance-ip>
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
| `SSH_PUBLIC_KEY` | *(empty)* | Empty = copy `ubuntu`'s `authorized_keys`. [Changing it on a re-run](#rotating-ssh_public_key-on-a-re-run) withdraws the key it replaces |
| `APP_SSH_USER` | `collavre` | Must match `KAMAL_SSH_USER`. Gets passwordless sudo — the maintenance commands below are sent non-interactively and cannot answer a prompt. [Changing it on a re-run](#changing-app_ssh_user-on-a-re-run) disarms the account it replaces |
| `PG_MAJOR` | `17` | Match the source database when restoring a dump. [Changing it on a re-run](#changing-pg_major-on-a-re-run) is refused, not converged |
| `DB_PASSWORD` | *(generated)* | Generated password is alphanumeric; a custom one is [percent-encoded into `DATABASE_URL`](#a-custom-db_password-is-percent-encoded-in-database_url) |
| `DB_USER` | `collavre_user` | [Changing it on a re-run](#changing-db_user-on-a-re-run) moves table ownership to the new role and takes `LOGIN` from the old one |
| `SWAP_SIZE_MB` | `2048` | `0` disables |
| `BACKUP_S3_URI` | *(empty)* | e.g. `s3://collavre-backups/pg` — PostgreSQL only, [not uploaded files](#backup_s3_uri-does-not-cover-uploaded-files) |

It also runs fine by hand on an existing instance, and re-running converges the
host instead of duplicating config:

```bash
sudo SSH_PUBLIC_KEY="ssh-ed25519 AAAA..." bash script/lightsail_launch.sh
sudo FORCE=1 bash script/lightsail_launch.sh   # after the first success
```

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
unchanged. A password you supply yourself may not be: `config/database.yml`
runs `URI.parse(ENV["DATABASE_URL"])` on boot, and that rejects `@`, `/`, `#`,
`%`, `?` and spaces in the user/password part outright — every Rails command in
the container would abort with `URI::InvalidURIError` before it reached the
database.

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

A `FORCE=1` re-run with a different `APP_SSH_USER` creates the new account and
then takes the `docker` and `sudo` groups back from the one it replaces, along
with its `sudoers.d` grant. Docker membership is the part that matters:
`docker run -v /:/host` is a root shell, so an account left in that group has
not been rotated away from in any meaningful sense — it has only lost the
slower route.

What the script will not do is delete the account or its `authorized_keys`. Its
only view of the host is the deploy user recorded in
`/var/lib/collavre/deploy_user`, and if that name were ever the instance's own
cloud user, deleting it would remove the last way in. So the run leaves an
ordinary, group-less account behind and says so in the launch log. Finish the
rotation by hand once you have confirmed you can reach the host as the new user:

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
./kamal.sh app stop
sudo apt-get install -y postgresql-<new>       # the script will not install it while 5432 is taken
sudo pg_dropcluster --stop <new> main          # apt just created an EMPTY one; it is not the upgrade
sudo pg_upgradecluster <old> main              # copies the data, and gives the new cluster 5432
sudo pg_dropcluster --stop <old> main
sudo FORCE=1 PG_MAJOR=<new> bash script/lightsail_launch.sh
./kamal.sh app boot
```

The second line is the one that is easy to skip and expensive to skip. Installing
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

So the run withdraws the key it installed last time, recorded in
`/var/lib/collavre/ssh_public_key.<user>`. Only that exact line goes: keys you
added by hand, and the cloud user's original key, are matched whole-line and
left alone.

The record is **per account**, because `authorized_keys` is. Changing
`APP_SSH_USER` and changing back is the case that needs it: rotating
`collavre`/key-A to `deploybot`/key-B leaves key-A in `collavre`'s file, which is
correct — that is not the file being rewritten, and the same re-run takes
`docker` and sudo away from `collavre`. But coming back later to
`collavre`/key-C regrants those privileges, and with one shared record the
withdrawal would be looking for key-B, which was never in that file. Key-A would
be root again, two rotations after you retired it. A host provisioned by an
earlier revision has its single `ssh_public_key` file adopted by the account the
next run names. The withdrawal happens *after* the new key is in place, so an
interrupted run leaves two working keys rather than none.

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
objects by hand, then re-run:

```bash
sudo -u postgres psql -v ON_ERROR_STOP=1 -d collavre_production <<'SQL'
DO $$
DECLARE r record;
BEGIN
  FOR r IN
    SELECT c.oid::regclass AS obj
    FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
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
sudo -u postgres psql -qtA -d collavre_production -c \
  "SELECT relkind, relname FROM pg_class c
     JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname NOT IN ('pg_catalog','information_schema')
      AND pg_get_userbyid(c.relowner) = 'postgres'"
```

Empty output means the transfer is complete. Setting `DB_USER` back to the old
value is the other way out, and leaves the rotation undone.

Rotating the *password* rather than the role needs none of this — set
`DB_PASSWORD`, re-run, and update `DATABASE_URL`.

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
KAMAL_SSH_USER=collavre
KAMAL_SSH_KEY_PATH=~/.ssh/<key matching the instance>
KAMAL_REGISTRY_USER=<docker hub user>
KAMAL_REGISTRY_PASSWORD=<docker hub access token>
DATABASE_URL=postgresql://collavre_user:<password>@172.17.0.1:5432/collavre_production
PORT=80
SOLID_QUEUE_IN_PUMA=true
```

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
    scp collavre.dump collavre@<instance-ip>:/tmp/collavre.dump.incoming &&
    ssh collavre@<instance-ip> \
      'mv /tmp/collavre.dump.incoming /tmp/collavre.dump &&
       pg_restore --no-owner --role=collavre_user --clean --if-exists \
         -d "postgresql://collavre_user:<password>@127.0.0.1:5432/collavre_production" \
         /tmp/collavre.dump &&
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
  ./kamal.sh setup
  ./kamal.sh app stop   # no writes while the schema is dropped and reloaded
  stop_status=$?

  # The task reads the SQLite file from inside the container. /rails/storage is
  # the plan42_storage volume, shared by every container of the app, and uid
  # 1000 is the image's `rails` user.
  # Stage under a temporary name and rename into place, so the task can only
  # ever see a complete file. stage_status covers the whole staging step.
  stage_status=1
  if [ "$stop_status" -eq 0 ]; then
    scp storage/production-primary.sqlite3 collavre@<instance-ip>:/tmp/ &&
      ssh collavre@<instance-ip> \
        'vol="$(docker volume inspect plan42_storage --format "{{.Mountpoint}}")" &&
         sudo install -o 1000 -g 1000 -m 0600 /tmp/production-primary.sqlite3 \
           "$vol/production-primary.sqlite3.incoming" &&
         sudo mv "$vol/production-primary.sqlite3.incoming" \
                 "$vol/production-primary.sqlite3" &&
         rm /tmp/production-primary.sqlite3'
    stage_status=$?
  fi

  if [ "$stop_status" -ne 0 ]; then
    echo "STOP FAILED: a container may still be serving and polling this database"
    echo "nothing was staged, granted or converted"
    echo "check './kamal.sh app details' before retrying — do not convert while it runs"
  elif [ "$stage_status" -ne 0 ]; then
    echo "STAGING FAILED: nothing was granted and nothing was converted"
    echo "the volume still holds whatever was there before — on a retry that is"
    echo "the stale snapshot the previous attempt deliberately kept"
    echo "app left stopped on purpose; re-stage before converting"
  else
    # The copy disables referential integrity, which is superuser-only.
    ssh collavre@<instance-ip> \
      "sudo -u postgres psql -c 'ALTER ROLE collavre_user SUPERUSER'"

    ./kamal.sh app exec \
      'bin/rails "db:sqlite_to_postgres[storage/production-primary.sqlite3,production]"' \
      -e MIGRATION_RUN_RESET:true
    copy_status=$?

    # Take the grant back whether or not the copy worked — a failed cutover is
    # precisely when it would otherwise sit there.
    ssh collavre@<instance-ip> \
      "sudo -u postgres psql -c 'ALTER ROLE collavre_user NOSUPERUSER'"
    revoke_status=$?

    # Clean up and boot only if both worked. Either failure leaves the app down.
    if [ "$copy_status" -eq 0 ] && [ "$revoke_status" -eq 0 ]; then
      ssh collavre@<instance-ip> \
        'sudo rm "$(docker volume inspect plan42_storage \
           --format "{{.Mountpoint}}")/production-primary.sqlite3"'

      ./kamal.sh app boot   # restart on the data you just loaded
    else
      [ "$revoke_status" -eq 0 ] ||
        echo "REVOKE FAILED: collavre_user is still a superuser — take it back by hand"
      [ "$copy_status" -eq 0 ] ||
        echo "COPY FAILED: this database is now empty or half-loaded"
      echo "app left stopped on purpose; do not boot it until the above is cleared"
    fi
  fi
  ```

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
sudo -u postgres psql -qd postgres -c \
  "ALTER DATABASE collavre_production CONNECTION LIMIT 0"

# Read the limit back rather than trusting that the line above ran. These
# blocks are pasted into an interactive shell with no `set -e`, so a failed
# ALTER just scrolls past — and if nothing happens to be attached a moment
# later, the count below reads 0 and the restore starts against a database
# that was never shut. `datconnlimit` is the state itself, so it cannot say
# "closed" about a door that is open.
shut=$(sudo -u postgres psql -qtAd postgres -c \
  "SELECT datconnlimit FROM pg_database WHERE datname = 'collavre_production'")

if [ "$shut" != 0 ]; then
  echo "REFUSING: could not shut collavre_production to the app."
  echo "  its connection limit is '$shut', not 0 — the ALTER above did not take"
  echo "  (wrong database name? not superuser? cluster gone?)"
  echo "nothing was dropped; fix that and re-run this block"
  # Its own status, not the refusal below: this block never shut the database,
  # so it must not "re-open" it either — that would lift a limit the operator
  # may have set themselves.
  restore_status=3
else

sudo -u postgres psql -qtAd postgres -c \
  "SELECT count(pg_terminate_backend(pid)) FROM pg_stat_activity
    WHERE datname = 'collavre_production' AND pid <> pg_backend_pid()"

# Now check, with the door confirmed shut — a point-in-time count taken before
# this would only have said the app happened to be between connections.
live=$(sudo -u postgres psql -qtA -d postgres -c \
  "SELECT count(*) FROM pg_stat_activity
    WHERE datname = 'collavre_production' AND pid <> pg_backend_pid()")

# A string comparison, not -ne: if the query above failed, $live is empty or an
# error message, and `[ "$live" -ne 0 ]` would error and be read as false —
# a gate that opens when the check breaks. Anything that is not exactly "0"
# stops here.
if [ "$live" != 0 ]; then
  echo "REFUSING: collavre_production is not confirmed idle (check returned: '$live')."
  sudo -u postgres psql -d postgres -c \
    "SELECT usename, client_addr, state, query
       FROM pg_stat_activity WHERE datname = 'collavre_production'"
  echo "run './kamal.sh app stop' on your workstation and check it succeeded"
  echo "nothing was dropped; re-run this block once the app is down"
  restore_status=2
else
  sudo -u postgres pg_restore --clean --if-exists -d collavre_production \
    /var/backups/collavre/collavre_production-YYYYmmdd-HHMMSS.dump
  restore_status=$?
fi

fi

# Re-open on the two paths where this block shut the door and the database is
# whole — a restore that succeeded, and a refusal that touched nothing. A
# database left at CONNECTION LIMIT 0 refuses the app at boot with "too many
# connections", which reads like a pool problem and not like a step this block
# forgot to undo, so it must not be left shut by accident. On the failure path
# it is left shut on purpose; on status 3 it was never shut to begin with.
if [ "$restore_status" -eq 0 ] || [ "$restore_status" -eq 2 ]; then
  sudo -u postgres psql -qd postgres -c \
    "ALTER DATABASE collavre_production CONNECTION LIMIT -1"
fi

if [ "$restore_status" -eq 0 ]; then
  echo "restored; boot the app from your workstation: ./kamal.sh app boot"
elif [ "$restore_status" -eq 2 ] || [ "$restore_status" -eq 3 ]; then
  : # refused before touching anything — see the message above
else
  echo "RESTORE FAILED: objects may be dropped or only partly reloaded."
  echo "collavre_production is LEFT AT 'CONNECTION LIMIT 0' deliberately: it is"
  echo "  now half-replaced, and a container that survived the stop must not"
  echo "  reconnect and write into it. pg_restore is a superuser and is exempt,"
  echo "  so fix the cause and run this block again — it needs no other step."
  echo "If instead you are abandoning the restore, re-open it by hand with:"
  echo "  sudo -u postgres psql -qd postgres -c \\"
  echo "    \"ALTER DATABASE collavre_production CONNECTION LIMIT -1\""
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
| `sudo: a password is required` | The deploy user has no password, so `%sudo` alone cannot authenticate it. `sudo ls /etc/sudoers.d/90-collavre-*` from the `ubuntu` account — missing means the host predates that grant; re-run the launch script with `FORCE=1` |
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
