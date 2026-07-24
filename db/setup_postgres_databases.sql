-- =============================================================================
-- setup_postgres_databases.sql
-- =============================================================================
--
-- Provision the production PostgreSQL database this app uses, owned by the
-- application role.
--
--   primary -> collavre_production   (real app data)
--
-- This app keeps everything in ONE database: the Solid Queue / Cache / Cable
-- tables (solid_queue_jobs, etc.) are created by a primary `db/migrate`
-- migration and live in the single `db/schema.rb` — there are no separate
-- queue/cache/cable schema files. The production topology (config/render.yaml)
-- sets only DATABASE_URL, so cache/queue/cable connect to this same database.
-- Do NOT create separate _cache/_queue/_cable databases: they would be empty
-- with no path to load the Solid tables, and CronScheduler/SolidQueue would
-- boot-fail with `relation "solid_queue_jobs" does not exist`.
--
-- The script is IDEMPOTENT: it only creates what is missing and re-asserts
-- ownership, so it is safe to re-run. It never drops a database or any data.
--
-- Usage (run as a superuser, e.g. postgres):
--   # 1) create the app role's password out of band (env, never shell history):
--   DB_PASSWORD='...' psql -v ON_ERROR_STOP=1 -f db/setup_postgres_databases.sql
--
--   # or against a remote server:
--   DB_PASSWORD='...' psql -h <host> -U postgres -d postgres \
--     -v ON_ERROR_STOP=1 -f db/setup_postgres_databases.sql
--
-- Overrides (all optional):
--   -v db_user=collavre_user          application role name (default collavre_user)
--   -v db_name=collavre_production     database name (default collavre_production)
--   DB_PASSWORD=...               (env) sets/updates the role password. If unset,
--                                 an existing role's password is left untouched
--                                 and a missing role is created with LOGIN only.
--
-- After this runs, point DATABASE_URL at this database and migrate data into it
-- with `bin/rails db:sqlite_to_postgres[...]` (see lib/tasks/db_convert.rake).
-- =============================================================================

\set ON_ERROR_STOP on

-- Defaults, only applied when not supplied via -v.
\if :{?db_user}
\else
  \set db_user 'collavre_user'
\endif
\if :{?db_name}
\else
  \set db_name 'collavre_production'
\endif

-- Read the desired role password from the environment (empty when unset).
-- printf avoids a trailing newline; works on psql 14+ (\getenv is 15+ only).
\set db_password `printf '%s' "${DB_PASSWORD:-}"`

\echo '--- Ensuring application role' :'db_user'

-- Create the login role if it does not exist yet (password set separately below).
SELECT format('CREATE ROLE %I LOGIN', :'db_user')
WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname = :'db_user')
\gexec

-- Set/update the password only when one was provided; otherwise leave it as is.
SELECT format('ALTER ROLE %I PASSWORD %L', :'db_user', :'db_password')
WHERE :'db_password' <> ''
\gexec

\echo '--- Ensuring database' :'db_name' 'owned by' :'db_user'

-- Create the database owned by the app role if it does not exist yet. CREATE
-- DATABASE cannot run inside a transaction/DO block, so we generate it with \gexec.
SELECT format('CREATE DATABASE %I OWNER %I', :'db_name', :'db_user')
WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = :'db_name')
\gexec

-- Re-assert ownership in case the database already existed with a different owner.
SELECT format('ALTER DATABASE %I OWNER TO %I', :'db_name', :'db_user')
\gexec

\echo '--- Done. Database:'
SELECT datname, pg_catalog.pg_get_userbyid(datdba) AS owner
FROM pg_database
WHERE datname = :'db_name';
