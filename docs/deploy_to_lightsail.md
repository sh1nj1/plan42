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
| `PG_MAJOR` | `17` | Match the source database when restoring a dump |
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
  It only adds its own SSH rule when nothing else allows the port.
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

### Rotating `SSH_PUBLIC_KEY` on a re-run

The third member of the same family, on the same account. A re-run with a
different `SSH_PUBLIC_KEY` adds the new key, and without anything further the
old one stays in `authorized_keys` — and that account is in `docker` with
passwordless sudo, so the key you believed you retired is still root on the
box. Rotating away from a leaked key would have withdrawn nothing while
reporting success.

So the run withdraws the key it installed last time, recorded in
`/var/lib/collavre/ssh_public_key`. Only that exact line goes: keys you added
by hand, and the cloud user's original key, are matched whole-line and left
alone. The withdrawal happens *after* the new key is in place, so an
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

One case is refused rather than converged: if the previous `DB_USER` was a
superuser (`DB_USER=postgres` on a first run is legal), the script logs a
warning and changes nothing. `NOLOGIN` on the cluster superuser locks every
operator out of administering it, and peer authentication needs `LOGIN` too, so
there is no way back in. Move ownership and retire that role by hand.

Rotating the *password* rather than the role needs none of this — set
`DB_PASSWORD`, re-run, and update `DATABASE_URL`.

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

  ```bash
  pg_dump --format=custom "$SOURCE_DATABASE_URL" -f collavre.dump
  scp collavre.dump collavre@<instance-ip>:/tmp/
  ssh collavre@<instance-ip> \
    'pg_restore --no-owner --role=collavre_user --clean --if-exists \
       -d "postgresql://collavre_user:<password>@127.0.0.1:5432/collavre_production" \
       /tmp/collavre.dump && rm /tmp/collavre.dump'
  ```

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

  # The task reads the SQLite file from inside the container. /rails/storage is
  # the plan42_storage volume, shared by every container of the app, and uid
  # 1000 is the image's `rails` user.
  # Stage under a temporary name and rename into place, so the task can only
  # ever see a complete file. stage_status covers the whole staging step.
  scp storage/production-primary.sqlite3 collavre@<instance-ip>:/tmp/ &&
    ssh collavre@<instance-ip> \
      'vol="$(docker volume inspect plan42_storage --format "{{.Mountpoint}}")" &&
       sudo install -o 1000 -g 1000 -m 0600 /tmp/production-primary.sqlite3 \
         "$vol/production-primary.sqlite3.incoming" &&
       sudo mv "$vol/production-primary.sqlite3.incoming" \
               "$vol/production-primary.sqlite3" &&
       rm /tmp/production-primary.sqlite3'
  stage_status=$?

  if [ "$stage_status" -ne 0 ]; then
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

  ADMIN_PASSWORD="$(openssl rand -base64 18)"   # not in shell history; print it below
  ./kamal.sh app exec 'bin/rails db:schema:load:primary db:seed' \
    -e DISABLE_DATABASE_ENVIRONMENT_CHECK:1 \
       DEFAULT_USER_EMAIL:you@example.com \
       DEFAULT_USER_PASSWORD:"$ADMIN_PASSWORD"
  load_status=$?

  if [ "$load_status" -eq 0 ]; then
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

# restore
sudo -u postgres pg_restore --clean --if-exists -d collavre_production \
  /var/backups/collavre/collavre_production-YYYYmmdd-HHMMSS.dump
```

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
