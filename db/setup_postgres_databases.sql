-- =============================================================================
-- setup_postgres_databases.sql
-- =============================================================================
--
-- Provision the four PostgreSQL databases this app uses in production, all owned
-- by the application role. Rails 8 keeps primary / cache / queue / cable in
-- SEPARATE databases (see config/database.yml). If they collapse onto one
-- physical database they share a single `schema_migrations` table and the
-- primary (version 2026...) and the Solid Cache/Queue/Cable schemas (version 1)
-- clobber each other, which breaks `db:migrate` on deploy.
--
--   primary -> collavre_production          (real app data)
--   cache   -> collavre_production_cache     (Solid Cache, volatile)
--   queue   -> collavre_production_queue     (Solid Queue, volatile)
--   cable   -> collavre_production_cable     (Solid Cable, volatile)
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
--   -v db_user=collavre_user      application role name (default collavre_user)
--   -v db_prefix=collavre_production   base DB name; the other three append
--                                 _cache/_queue/_cable (default collavre_production)
--   DB_PASSWORD=...               (env) sets/updates the role password. If unset,
--                                 an existing role's password is left untouched
--                                 and a missing role is created with LOGIN only.
--
-- After this runs, point the four *_DATABASE_URL env vars at these databases and
-- migrate data into the primary with `bin/rails db:sqlite_to_postgres[...]`
-- (see lib/tasks/db_convert.rake). The cache/queue/cable databases hold volatile
-- data only — never copy rows into them; `db:prepare` loads their schemas.
-- =============================================================================

\set ON_ERROR_STOP on

-- Defaults, only applied when not supplied via -v.
\if :{?db_user}
\else
  \set db_user 'collavre_user'
\endif
\if :{?db_prefix}
\else
  \set db_prefix 'collavre_production'
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

\echo '--- Ensuring databases owned by' :'db_user'

-- Create each missing database owned by the app role. CREATE DATABASE cannot run
-- inside a transaction/DO block, so we generate the statements with \gexec.
SELECT format('CREATE DATABASE %I OWNER %I', :'db_prefix' || suffix, :'db_user')
FROM (VALUES (''), ('_cache'), ('_queue'), ('_cable')) AS d(suffix)
WHERE NOT EXISTS (
  SELECT FROM pg_database WHERE datname = :'db_prefix' || suffix
)
\gexec

-- Re-assert ownership in case a database already existed with a different owner.
SELECT format('ALTER DATABASE %I OWNER TO %I', :'db_prefix' || suffix, :'db_user')
FROM (VALUES (''), ('_cache'), ('_queue'), ('_cable')) AS d(suffix)
\gexec

\echo '--- Done. Databases:'
SELECT datname, pg_catalog.pg_get_userbyid(datdba) AS owner
FROM pg_database
WHERE datname IN (
  :'db_prefix',
  :'db_prefix' || '_cache',
  :'db_prefix' || '_queue',
  :'db_prefix' || '_cable'
)
ORDER BY datname;
