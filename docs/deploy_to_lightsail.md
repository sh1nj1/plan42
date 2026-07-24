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
| `SSH_PUBLIC_KEY` | *(empty)* | Empty = copy `ubuntu`'s `authorized_keys` |
| `APP_SSH_USER` | `collavre` | Must match `KAMAL_SSH_USER` |
| `PG_MAJOR` | `17` | Match the source database when restoring a dump |
| `DB_PASSWORD` | *(generated)* | Generated password is alphanumeric; a custom one is [percent-encoded into `DATABASE_URL`](#a-custom-db_password-is-percent-encoded-in-database_url) |
| `SWAP_SIZE_MB` | `2048` | `0` disables |
| `BACKUP_S3_URI` | *(empty)* | e.g. `s3://collavre-backups/pg` — PostgreSQL only, [not uploaded files](#backup_s3_uri-does-not-cover-uploaded-files) |

It also runs fine by hand on an existing instance, and re-running converges the
host instead of duplicating config:

```bash
sudo SSH_PUBLIC_KEY="ssh-ed25519 AAAA..." bash script/lightsail_launch.sh
sudo FORCE=1 bash script/lightsail_launch.sh   # after the first success
```

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
the SQLite converter needs the app image and so runs after it, app stopped.

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
  can reach both ends. `DATABASE_URL` names `172.17.0.1`, which by design
  answers only on the host, so running the task from your workstation dials
  your own machine instead — and overriding the URL on the command line does
  not help, because `config/boot.rb` uses `Dotenv.overload`: `.env.production`
  puts `172.17.0.1` back over whatever you passed.

  ```bash
  ./kamal.sh setup
  ./kamal.sh app stop   # no writes while the schema is dropped and reloaded

  # The task reads the SQLite file from inside the container. /rails/storage is
  # the plan42_storage volume, shared by every container of the app, and uid
  # 1000 is the image's `rails` user.
  scp storage/production-primary.sqlite3 collavre@<instance-ip>:/tmp/
  ssh collavre@<instance-ip> \
    'sudo install -o 1000 -g 1000 -m 0600 /tmp/production-primary.sqlite3 \
       "$(docker volume inspect plan42_storage --format "{{.Mountpoint}}")/" &&
     rm /tmp/production-primary.sqlite3'

  # The copy disables referential integrity, which is superuser-only.
  ssh collavre@<instance-ip> \
    "sudo -u postgres psql -c 'ALTER ROLE collavre_user SUPERUSER'"

  ./kamal.sh app exec \
    'bin/rails "db:sqlite_to_postgres[storage/production-primary.sqlite3,production]"' \
    -e MIGRATION_RUN_RESET:true

  ssh collavre@<instance-ip> \
    "sudo -u postgres psql -c 'ALTER ROLE collavre_user NOSUPERUSER'"
  ssh collavre@<instance-ip> \
    'sudo rm "$(docker volume inspect plan42_storage \
       --format "{{.Mountpoint}}")/production-primary.sqlite3"'

  ./kamal.sh app boot   # restart on the data you just loaded
  ```

  The grant is not optional. The launch script creates the role with
  `CREATE ROLE ... LOGIN` and nothing else, and the copy runs
  `ALTER TABLE ... DISABLE TRIGGER ALL`, which needs a superuser — owning the
  table is not enough. The task checks this up front and aborts with
  instructions rather than dying halfway through with a `ForeignKeyViolation`,
  so a forgotten grant costs you a message, not a half-loaded database. Take it
  back afterwards: the other route the task offers,
  `MIGRATION_RUN_USER=postgres`, would mean giving the superuser role a
  password that every container on the host could then authenticate with.

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
  ./kamal.sh app exec 'bin/rails db:schema:load db:seed' \
    -e DISABLE_DATABASE_ENVIRONMENT_CHECK:1
  ./kamal.sh app boot   # restart on the schema you just loaded
  ```

  `db/schema.rb` declares every table `force: :cascade`, so the load replaces
  the replayed tables instead of colliding with them, and it stamps
  `schema_migrations` up to the schema version — the next boot's `db:migrate`
  is a no-op.

  `DISABLE_DATABASE_ENVIRONMENT_CHECK` is not optional here. `db:schema:load`
  runs `check_protected_environments` first, which aborts with
  `ActiveRecord::ProtectedEnvironmentError` once the database records
  `production` in `ar_internal_metadata` — which is exactly what the replay in
  the preceding `setup` just wrote. Note the flag *trails* the command: `-e`
  takes a Thor hash and greedily consumes every following argument containing a
  colon, so putting it first would swallow `bin/rails db:schema:load db:seed`
  into the hash and leave kamal with no command to run.

  This still works when the replay *fails* and `setup` dies at `app boot`: the
  env file and the network are uploaded before the container is started, and
  `app exec` runs a **new** container whose command is `bin/rails db:schema:load`,
  which the entrypoint does not migrate for (it only migrates the
  `./bin/rails server` command line). Run the `app exec` above and then
  `./kamal.sh deploy`.

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
