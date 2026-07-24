# Deploy to AWS Lightsail (app + PostgreSQL on one instance)

This runbook provisions a single Lightsail instance that runs both PostgreSQL
and the Collavre container, deployed with Kamal from your workstation.

[`script/lightsail_launch.sh`](../script/lightsail_launch.sh) does the host
preparation. It never builds or starts the app — `bin/kamal setup` does that.

| The launch script sets up | You still do |
| --- | --- |
| Base packages, timezone, swap, SSH hardening | Lightsail console firewall (80/443) |
| Deploy user in the `docker` group | `.env.production` on your workstation |
| Docker CE + buildx + compose, capped container logs | `bin/kamal setup` |
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
| `DB_PASSWORD` | *(generated)* | Generated password is URL-safe |
| `SWAP_SIZE_MB` | `2048` | `0` disables |
| `BACKUP_S3_URI` | *(empty)* | e.g. `s3://collavre-backups/pg` |

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

`kamal.sh` wraps `bin/kamal` with `.env.production` loaded.

## 5. Get data into the new database

`bin/docker-entrypoint` runs `db:migrate` on boot. On a brand-new database that
replays every migration from zero, and `db/schema.rb` is known to drift from a
full replay — so if you are bringing existing data, **restore it before the
first deploy**, while the database is still reachable without the app:

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
  (`lib/tasks/db_convert.rake`).

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
| App: `password authentication failed` | `sudo cat /var/lib/collavre/db_password` vs `DATABASE_URL` |
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
