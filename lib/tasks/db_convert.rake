# frozen_string_literal: true

# =============================================================================
# db:sqlite_to_postgres
# =============================================================================
#
# One-shot data migration from a SQLite primary database into the PostgreSQL
# database configured for a target Rails environment.
#
# Design ("simplest and error-free"):
#   * The TARGET schema is created by Rails from db/schema.rb (`db:schema:load`
#     semantics), so every column gets its correct Postgres type
#     (boolean / json / bytea / decimal ...). We never let SQLite's dynamic
#     typing leak into Postgres.
#   * We read RAW column values from SQLite (no application models), so encrypted
#     / serialized columns are copied verbatim and stay valid. Each value is then
#     quoted for its TARGET column type (0/1 -> boolean, JSON text -> json,
#     blob -> bytea), so SQLite's dynamic typing never leaks into Postgres.
#   * Referential integrity is disabled during the copy, so table order and FKs
#     never block the load. Primary-key sequences are reset afterwards.
#   * Row counts are compared per table at the end; a mismatch fails the task.
#
# Usage:
#   # Copy the 700MB production SQLite primary DB into the Postgres database
#   # that `production` resolves to (DATABASE_URL must point at Postgres):
#   DATABASE_URL=postgresql://user:pw@host:5432/collavre_production \
#     bin/rails "db:sqlite_to_postgres[storage/production-primary.sqlite3,production]"
#
#   # Local one-shot: keep the app's own DATABASE_URL (app role) and just supply
#   # a superuser to RUN the copy with. Works even when dotenv `overload` rewrites
#   # a CLI DATABASE_URL back to the app role (which is why passing the superuser
#   # via DATABASE_URL alone does NOT work in this repo):
#   MIGRATION_RUN_USER=soonoh \
#     bin/rails "db:sqlite_to_postgres[storage/development-primary.sqlite3,development]"
#
# Options (environment variables):
#   BATCH_SIZE=1000        rows per INSERT batch (default 1000)
#   SKIP_SCHEMA_LOAD=1     do NOT load db/schema.rb into the target first
#                          (use when the target already has an empty schema)
#   ONLY=t1,t2             copy only these tables
#   EXCLUDE=t1,t2          skip these tables (in addition to the built-ins)
#   MIGRATION_RUN_USER=name       run the migration as this (superuser) role,
#                          connecting to the SAME target database. Use this when
#                          the app's DATABASE_URL points at a non-superuser role:
#                          the RI-disable step needs a superuser, but the app keeps
#                          its own role and ownership is handed back to it at the
#                          end. Preferred locally because dotenv `overload` clobbers
#                          a CLI DATABASE_URL, but never touches MIGRATION_RUN_*.
#   MIGRATION_RUN_PASSWORD=pw      password for MIGRATION_RUN_USER. If a user is
#                          given but this is unset and a TTY is attached, the task
#                          prompts (hidden input). Omit entirely for trust/peer auth.
#   MIGRATION_RUN_RESET=true      before loading the schema, DROP SCHEMA public
#                          CASCADE and recreate it — a full clean slate. Use when
#                          the target already holds data or stale tables from old
#                          migrations (schema:load's force: :cascade only drops
#                          the tables db/schema.rb still knows about). Equivalent
#                          to dropdb+createdb but works while connected to the
#                          target. Superuser-only (already required). Mutually
#                          exclusive with SKIP_SCHEMA_LOAD.
#   APP_ROLE=name          after the copy, reassign ownership of every
#                          public-schema object to this role. Default: the app's
#                          own role when MIGRATION_RUN_USER is used, otherwise the
#                          target database's owner. A superuser-run schema:load
#                          owns every object, so the app role would otherwise get
#                          "permission denied"; the task fixes this automatically.
#
# Notes:
#   * Only the PRIMARY database holds real data. cache/queue/cable are volatile
#     (Solid Cache/Queue/Cable) and are intentionally NOT migrated — the schema
#     load creates their empty tables in the same Postgres database.
#   * Run inside a maintenance window with the app stopped: rows inserted into
#     SQLite while the copy runs would be lost.
#   * Without MIGRATION_RUN_RESET the task does NOT reset the database: it only
#     drops+recreates the tables db/schema.rb knows about (force: :cascade), so a
#     pre-existing target keeps any stale tables absent from schema.rb and holds
#     an open-connection risk if the app is still attached. Pass
#     MIGRATION_RUN_RESET=true (or reset the DB by hand first) for a clean slate.
#   * Active Storage: only DB metadata rows are copied. Blob files on disk/S3
#     are untouched — leave the storage volume/bucket as-is.
#   * Foreign keys are bypassed via disable_referential_integrity, which issues
#     ALTER TABLE ... DISABLE TRIGGER ALL. That disables the internal RI/system
#     triggers, which is SUPERUSER-ONLY — being the table owner is NOT enough.
#     The task ENFORCES this up front: if the target role is not a superuser it
#     aborts with copy/paste instructions, instead of failing deep in the copy
#     with a confusing ForeignKeyViolation (first offender: activity_logs). On a
#     Kamal Postgres accessory the app role is a superuser, so the check passes.
#   * Ownership after a SUPERUSER-run cutover: every table/sequence created by
#     schema:load is then owned by that superuser, so the app role would hit
#     "permission denied for table ..." on every query even if it owns the
#     database. The task FIXES this automatically at the end: it reassigns every
#     public-schema object to the app role (the target database's owner, or
#     APP_ROLE) and prints the equivalent psql for the record. It is a no-op when
#     the connecting role already owns everything (e.g. Kamal, app role == owner).
#     (REASSIGN OWNED BY is intentionally avoided — the bootstrap superuser owns
#     pinned system objects, so it is too broad.)
# =============================================================================

# Named abstract model that owns the SOURCE (SQLite) connection. Rails 8 forbids
# establish_connection on an anonymous class, so this must be a real constant.
class SqliteMigrationSource < ActiveRecord::Base
  self.abstract_class = true
end

namespace :db do
  desc "Copy a SQLite primary DB into the target environment's PostgreSQL DB " \
       "([sqlite_path,target_env])"
  task :sqlite_to_postgres, %i[sqlite_path target_env] => :environment do |_task, args|
    sqlite_path = args[:sqlite_path]
    target_env  = args[:target_env]

    abort "ERROR: sqlite_path is required, e.g. db:sqlite_to_postgres[storage/production-primary.sqlite3,production]" if sqlite_path.blank?
    abort "ERROR: target_env is required, e.g. db:sqlite_to_postgres[storage/production-primary.sqlite3,production]" if target_env.blank?

    sqlite_path = File.expand_path(sqlite_path)
    abort "ERROR: SQLite file not found: #{sqlite_path}" unless File.file?(sqlite_path)

    batch_size = Integer(ENV.fetch("BATCH_SIZE", 1000))
    skip_schema_load = ENV["SKIP_SCHEMA_LOAD"].present?
    reset_target     = ActiveModel::Type::Boolean.new.cast(ENV["MIGRATION_RUN_RESET"])
    only_tables    = ENV["ONLY"].to_s.split(",").map(&:strip).reject(&:empty?)
    exclude_tables = ENV["EXCLUDE"].to_s.split(",").map(&:strip).reject(&:empty?)

    # A reset drops every table, so the schema MUST be reloaded afterwards.
    if reset_target && skip_schema_load
      abort "ERROR: MIGRATION_RUN_RESET and SKIP_SCHEMA_LOAD are mutually exclusive — " \
            "a reset wipes the whole schema, so it must be reloaded, not skipped."
    end

    # Tables Rails manages itself; schema:load populates these to the correct
    # versions, so copying them from SQLite would only cause conflicts.
    builtin_excludes = %w[schema_migrations ar_internal_metadata]

    # --- Resolve the TARGET database config (primary role) -------------------
    target_config = ActiveRecord::Base.configurations
      .configs_for(env_name: target_env, name: "primary", include_hidden: true)

    abort "ERROR: no 'primary' database config for environment '#{target_env}'" if target_config.nil?

    unless target_config.adapter.to_s.start_with?("postgresql")
      abort <<~MSG
        ERROR: target '#{target_env}' primary adapter is '#{target_config.adapter}', not postgresql.
               Set DATABASE_URL to your PostgreSQL server so the '#{target_env}'
               environment resolves to Postgres, then re-run.
      MSG
    end

    # --- Build the connection used to RUN the migration ----------------------
    # The copy disables referential integrity, a superuser-only operation. When
    # the app's DATABASE_URL points at a non-superuser role, pass a superuser via
    # MIGRATION_RUN_USER and we connect to the SAME target database as that role.
    # (Preferred locally: this repo's dotenv `overload` rewrites a CLI DATABASE_URL
    # back to the app role, but never touches MIGRATION_RUN_*.) The app keeps its
    # own role, so ownership is handed back to it at the end.
    run_user = ENV["MIGRATION_RUN_USER"].presence
    run_config = target_config
    # APP_ROLE default: the app's own role when we only added a superuser for the
    # run; otherwise nil, so reassign falls back to the target database's owner.
    app_role = ENV["APP_ROLE"].presence
    if run_user
      run_config = ActiveRecord::DatabaseConfigurations::HashConfig.new(
        target_config.env_name, target_config.name,
        target_config.configuration_hash.merge(
          username: run_user, password: resolve_run_password(run_user)
        )
      )
      app_role ||= target_config.configuration_hash[:username]
    end

    puts "=" * 72
    puts "SQLite -> PostgreSQL data migration"
    puts "  source : #{sqlite_path}"
    puts "  target : #{target_env} / primary -> #{safe_target_desc(target_config)}"
    puts "  run as : #{run_config.configuration_hash[:username]}#{' (MIGRATION_RUN_USER)' if run_user}"
    puts "  batch  : #{batch_size} rows"
    puts "=" * 72

    # --- Open the SOURCE (SQLite) on its own connection ----------------------
    SqliteMigrationSource.establish_connection(adapter: "sqlite3", database: sqlite_path)
    source_conn = SqliteMigrationSource.connection

    # --- Connect the primary (default) connection to the TARGET --------------
    ActiveRecord::Base.establish_connection(run_config)

    # --- Require a SUPERUSER role (RI disable is superuser-only) --------------
    # Fail fast with instructions instead of dying deep in the copy with a
    # confusing ForeignKeyViolation once DISABLE TRIGGER ALL silently no-ops.
    ensure_target_superuser!(ActiveRecord::Base.connection, sqlite_path, target_env)

    # --- Optionally reset the target for a truly clean slate -----------------
    # schema:load uses force: :cascade, which only drops the tables db/schema.rb
    # knows about — stale tables left by old migrations survive. A full reset
    # drops the entire public schema first, so the load starts from nothing
    # (same clean slate as dropdb+createdb, but without a second connection,
    # which is impossible while connected to the target database).
    if reset_target
      puts "\n[reset] MIGRATION_RUN_RESET set — dropping & recreating schema 'public' (ALL data)."
      reset_public_schema!(ActiveRecord::Base.connection, app_role)
      puts "[reset] Done."
    end

    # --- Load schema into the target (correct Postgres types) ----------------
    if skip_schema_load
      puts "\n[schema] SKIP_SCHEMA_LOAD set — assuming target schema already exists."
    else
      puts "\n[schema] Loading db/schema.rb into the target database..."
      load_portable_schema(run_config)
      # load_schema may leave the connection pointed elsewhere; re-pin to target.
      ActiveRecord::Base.establish_connection(run_config)
      puts "[schema] Done."
      stamp_all_migrations(ActiveRecord::Base.connection)
    end
    target_conn = ActiveRecord::Base.connection

    # --- Decide which tables to copy -----------------------------------------
    source_tables = source_conn.tables.sort
    tables = source_tables
    tables &= only_tables if only_tables.any?
    tables -= builtin_excludes
    tables -= exclude_tables

    missing_in_target = tables.reject { |t| target_conn.data_source_exists?(t) }
    if missing_in_target.any?
      abort "ERROR: these source tables do not exist in the target schema " \
            "(schema out of date?): #{missing_in_target.join(', ')}"
    end

    puts "\n[copy] #{tables.size} tables to copy.\n\n"

    # --- Copy rows -----------------------------------------------------------
    totals = {}
    target_conn.disable_referential_integrity do
      tables.each do |table|
        totals[table] = copy_table(
          source_conn: source_conn,
          target_conn: target_conn,
          table: table,
          batch_size: batch_size
        )
      end
    end

    # --- Reset primary-key sequences -----------------------------------------
    puts "\n[sequences] Resetting primary-key sequences..."
    tables.each do |table|
      target_conn.reset_pk_sequence!(table)
    rescue => e
      warn "  [warn] could not reset sequence for #{table}: #{e.message}"
    end
    puts "[sequences] Done."

    # --- Reassign ownership to the app role ----------------------------------
    # schema:load ran as the (required) superuser, so it owns every object; hand
    # them to the app role or the app gets "permission denied for table ...".
    reassign_owner_to_app_role(target_conn, app_role)

    # --- Verify row counts ---------------------------------------------------
    puts "\n[verify] Comparing row counts (source vs target)..."
    mismatches = []
    tables.each do |table|
      src = source_conn.select_value(%(SELECT COUNT(*) FROM "#{table}")).to_i
      dst = target_conn.select_value(%(SELECT COUNT(*) FROM "#{table}")).to_i
      status = src == dst ? "ok" : "MISMATCH"
      mismatches << [ table, src, dst ] if src != dst
      printf "  %-45s %10d -> %-10d %s\n", table, src, dst, status
    end

    puts "\n" + ("=" * 72)
    if mismatches.any?
      puts "FAILED: #{mismatches.size} table(s) with row-count mismatch:"
      mismatches.each { |t, s, d| puts "  #{t}: source=#{s} target=#{d}" }
      abort "Migration incomplete — investigate mismatched tables before switching over."
    else
      grand = totals.values.sum
      puts "SUCCESS: #{tables.size} tables, #{grand} rows copied and verified."
      puts "Next: point the app's DATABASE_URL at PostgreSQL and redeploy."
    end
    puts "=" * 72
  end

  # Resolve the password for MIGRATION_RUN_USER. Precedence: MIGRATION_RUN_PASSWORD
  # (even empty, for explicit no-password); else prompt with hidden input when a
  # TTY is attached (keeps the password out of shell history / the process list);
  # else nil, for local trust/peer auth. Returns nil for a blank password.
  def resolve_run_password(run_user)
    return ENV["MIGRATION_RUN_PASSWORD"].presence if ENV.key?("MIGRATION_RUN_PASSWORD")
    return nil unless $stdin.tty?

    require "io/console"
    $stderr.print "Password for PostgreSQL role '#{run_user}' (blank for trust/peer auth): "
    pw = begin
      $stdin.noecho(&:gets)
    rescue StandardError
      $stdin.gets # no console control available — fall back to echoed input
    end
    $stderr.puts
    pw.to_s.chomp.presence
  end

  # Abort with copy/paste instructions unless the target connection is a
  # PostgreSQL superuser. The copy relies on disable_referential_integrity
  # (ALTER TABLE ... DISABLE TRIGGER ALL), which silently no-ops for a
  # non-superuser and then lets the alphabetical insert order raise a confusing
  # ForeignKeyViolation (first offender: activity_logs). Fail early instead.
  def ensure_target_superuser!(conn, sqlite_path, target_env)
    return if ActiveModel::Type::Boolean.new.cast(conn.select_value("SELECT current_setting('is_superuser')"))

    role = conn.select_value("SELECT current_user")
    rel_sqlite = sqlite_path.sub("#{Rails.root}/", "")
    abort <<~MSG
      #{'=' * 72}
      ERROR: connected as role '#{role}', which is NOT a PostgreSQL superuser.

      This migration disables referential integrity (ALTER TABLE ... DISABLE
      TRIGGER ALL) during the copy — a SUPERUSER-ONLY operation. Being the
      table/database owner is NOT enough. Without it the FK system triggers stay
      on and the alphabetical insert order raises ForeignKeyViolation (first
      offender: activity_logs).

      Re-run so the migration connects as a superuser. Simplest — keep the app's
      DATABASE_URL and just name a superuser to run the copy with:
        MIGRATION_RUN_USER=<superuser> [MIGRATION_RUN_PASSWORD=<pw>] \\
          bin/rails "db:sqlite_to_postgres[#{rel_sqlite},#{target_env}]"

      (Omit MIGRATION_RUN_PASSWORD for local trust/peer auth; with a TTY you'll be
      prompted for it otherwise.) This is the reliable local path because this
      repo's dotenv `overload` rewrites a CLI DATABASE_URL back to the app role —
      so passing the superuser via DATABASE_URL alone gets silently clobbered.
      Alternatively point the whole DATABASE_URL at a superuser where dotenv does
      not override it:
        DATABASE_URL=postgresql://<superuser>@<host>/<db> \\
          bin/rails "db:sqlite_to_postgres[#{rel_sqlite},#{target_env}]"

      Either way the copied objects are owned by that superuser; this task
      reassigns them to the app role automatically at the end (override with
      APP_ROLE). On a Kamal Postgres accessory the app role is already a
      superuser, so this check passes there automatically.
      #{'=' * 72}
    MSG
  end

  # Drop and recreate the target's public schema for a full clean slate, run
  # before schema:load. DROP SCHEMA public CASCADE removes EVERY object —
  # including stale tables absent from db/schema.rb that force: :cascade would
  # leave behind — so the reload starts from nothing, matching dropdb+createdb
  # without a second connection. Superuser-/owner-only; the migration already
  # enforces superuser. Restores the standard grants (and, when known, hands the
  # fresh schema to +app_role+) so the non-superuser app role keeps USAGE/CREATE
  # after the later table-ownership reassignment.
  def reset_public_schema!(conn, app_role)
    conn.execute("DROP SCHEMA IF EXISTS public CASCADE")
    conn.execute("CREATE SCHEMA public")
    # A freshly created schema (PG 15+) grants nothing to PUBLIC; restore the
    # historical default so any role can use it, as dropdb+createdb would.
    conn.execute("GRANT ALL ON SCHEMA public TO public")
    conn.execute("ALTER SCHEMA public OWNER TO #{conn.quote_column_name(app_role)}") if app_role.present?
  end

  # Reassign every public-schema table/sequence/view to the application role.
  # A superuser-run schema:load owns every object, so without this the app role
  # gets "permission denied for table ..." on every query. +app_role+ is resolved
  # by the caller (APP_ROLE, or the app's own role when MIGRATION_RUN_USER added a
  # superuser only for the run); when blank it falls back to the target DATABASE's
  # owner (createdb --owner=<app_role>). No-op when the connecting role already
  # owns everything (Kamal).
  def reassign_owner_to_app_role(conn, app_role = nil)
    current_role = conn.select_value("SELECT current_user")
    app_role = app_role.presence || conn.select_value(<<~SQL).to_s
      SELECT pg_catalog.pg_get_userbyid(datdba)
      FROM pg_database WHERE datname = current_database()
    SQL

    if app_role.empty? || app_role == current_role
      puts "\n[ownership] Objects already owned by the connecting role " \
           "('#{current_role}') — no reassignment needed."
      return
    end

    puts "\n[ownership] Reassigning public-schema objects to app role '#{app_role}'..."
    qrole = conn.quote_column_name(app_role)
    # Tables / partitioned tables / views / matviews, plus only STANDALONE
    # sequences. A sequence owned by a table column (serial deptype 'a' or
    # identity 'i') cannot have its owner changed on its own — Postgres raises
    # "cannot change owner of sequence ...". Its owner follows the owning table's
    # owner automatically, so reassigning the tables covers those sequences.
    objects = conn.select_rows(<<~SQL)
      SELECT c.relkind, c.relname
      FROM pg_class c
      JOIN pg_namespace n ON n.oid = c.relnamespace
      WHERE n.nspname = 'public'
        AND (
          c.relkind IN ('r', 'p', 'v', 'm')
          OR (c.relkind = 'S' AND NOT EXISTS (
            SELECT 1 FROM pg_depend d
            WHERE d.classid = 'pg_class'::regclass
              AND d.objid = c.oid
              AND d.deptype IN ('a', 'i')
              AND d.refobjsubid <> 0
          ))
        )
    SQL

    count = 0
    objects.each do |relkind, relname|
      keyword =
        case relkind
        when "S" then "SEQUENCE"
        when "v" then "VIEW"
        when "m" then "MATERIALIZED VIEW"
        else "TABLE" # 'r' ordinary, 'p' partitioned
        end
      obj = "public.#{conn.quote_column_name(relname)}"
      conn.execute("ALTER #{keyword} #{obj} OWNER TO #{qrole}")
      count += 1
    end
    puts "[ownership] Reassigned #{count} objects to '#{app_role}'."
    puts "[ownership] Equivalent psql (for the record):"
    puts ownership_psql_hint(app_role).gsub(/^/, "  ")
  rescue StandardError => e
    # Data is already copied — don't fail the whole run. Print the exact psql to
    # finish the ownership handoff manually (run as a superuser).
    warn "\n  [warn] ownership reassignment failed: #{e.message}"
    warn "  Run this as a superuser to grant the app role access:"
    warn ownership_psql_hint(app_role.to_s.empty? ? "<app_role>" : app_role).gsub(/^/, "  ")
  end

  # The psql that reassigns every public-schema object to +app_role+, shown so a
  # cutover is reproducible / recoverable by hand.
  def ownership_psql_hint(app_role)
    <<~SQL
      psql -d <database> <<'EOSQL'
      DO $$ DECLARE r RECORD; BEGIN
        FOR r IN SELECT c.relkind, c.relname FROM pg_class c
                 JOIN pg_namespace n ON n.oid = c.relnamespace
                 WHERE n.nspname = 'public'
                   AND (c.relkind IN ('r','p','v','m')
                        OR (c.relkind = 'S' AND NOT EXISTS (
                          SELECT 1 FROM pg_depend d
                          WHERE d.classid = 'pg_class'::regclass AND d.objid = c.oid
                            AND d.deptype IN ('a','i') AND d.refobjsubid <> 0))) LOOP
          EXECUTE format('ALTER %s public.%I OWNER TO %I',
            CASE r.relkind WHEN 'S' THEN 'SEQUENCE' WHEN 'v' THEN 'VIEW'
                           WHEN 'm' THEN 'MATERIALIZED VIEW' ELSE 'TABLE' END,
            r.relname, '#{app_role}');
        END LOOP;
      END $$;
      EOSQL
    SQL
  end

  # Copy one table from source (SQLite) to target (Postgres) using keyset
  # pagination on ROWID. Each value is quoted according to its TARGET column type
  # so SQLite 0/1 -> boolean, JSON text -> json, blob -> bytea all convert
  # correctly, and encrypted/serialized text is copied verbatim.
  def copy_table(source_conn:, target_conn:, table:, batch_size:)
    total = source_conn.select_value(%(SELECT COUNT(*) FROM "#{table}")).to_i
    if total.zero?
      printf "  %-45s %s\n", table, "empty"
      return 0
    end

    target_columns = target_conn.columns(table).index_by(&:name)
    quoted_table = target_conn.quote_table_name(table)

    copied = 0
    last_rowid = nil
    loop do
      where = last_rowid ? "WHERE ROWID > #{Integer(last_rowid)}" : ""
      result = source_conn.select_all(
        %(SELECT ROWID AS __rowid, * FROM "#{table}" #{where} ORDER BY ROWID LIMIT #{Integer(batch_size)})
      )
      break if result.empty?

      rows = result.to_a
      last_rowid = rows.last["__rowid"]

      # Only copy source columns that also exist in the target schema.
      source_cols = result.columns - [ "__rowid" ]
      col_names = source_cols.select { |c| target_columns.key?(c) }
      quoted_cols = col_names.map { |c| target_conn.quote_column_name(c) }.join(", ")

      # Row-count verification cannot detect a column present in SQLite but
      # absent from db/schema.rb — its data is silently dropped. Warn once so a
      # stale schema doesn't cause invisible data loss.
      dropped = source_cols - col_names
      if dropped.any? && !@warned_dropped_cols&.include?(table)
        (@warned_dropped_cols ||= []) << table
        warn "\n  [warn] #{table}: source columns not in target schema, NOT copied: #{dropped.join(', ')}"
      end

      tuples = rows.map do |row|
        "(" + col_names.map do |c|
          quote_for_column(target_conn, target_columns[c], row[c])
        end.join(", ") + ")"
      end.join(", ")

      target_conn.execute(%(INSERT INTO #{quoted_table} (#{quoted_cols}) VALUES #{tuples}))
      copied += rows.size
      printf "\r  %-45s %10d / %-10d", table, copied, total
    end

    printf "\r  %-45s %10d / %-10d done\n", table, copied, total
    copied
  end

  # Quote a raw SQLite value as a SQL literal for the given target column.
  # SQLite's dynamic typing means values arrive as ints/strings/blobs; we map
  # them to the target column's Postgres type explicitly.
  def quote_for_column(conn, column, raw)
    return "NULL" if raw.nil?

    case column.type
    when :boolean
      # SQLite stores booleans as 0/1 (or occasionally 't'/'f').
      ActiveModel::Type::Boolean.new.cast(raw) ? "TRUE" : "FALSE"
    when :binary
      # Let the adapter emit a proper bytea literal (respects standard_conforming_strings).
      conn.quote(ActiveRecord::Type::Binary::Data.new(raw.to_s))
    when :json, :jsonb
      # The SQLite value is already JSON text; insert it verbatim (do NOT
      # re-serialize, or it becomes a double-encoded JSON string). Postgres
      # casts the unknown-type string literal into json/jsonb.
      conn.quote(raw.to_s)
    else
      # integer / decimal / float / string / text / datetime / date / uuid ...
      conn.quote(raw)
    end
  end

  # Load db/schema.rb into the target, translating SQLite-only expression indexes
  # into their PostgreSQL equivalents. SQLite dumps JSON expression indexes using
  # json_extract(col, '$.key'); PostgreSQL needs (col ->> 'key'). Without this,
  # db:schema:load fails on Postgres with "function json_extract does not exist".
  # Fully populate schema_migrations after a schema:load.
  #
  # Why: schema:load's assume_migrated_upto_version stamps only versions from the
  # primary db_config's migrations_paths (nil -> just "db/migrate", 7 files here),
  # leaving the ~160 engine migrations unstamped. db:migrate, however, reads
  # DatabaseTasks.migrations_paths (primary + every engine that appends its path),
  # so on deploy it treats those engine migrations as pending and re-runs them
  # against already-existing tables -> "relation already exists". Stamping the full
  # set here makes db:migrate a no-op, which is correct: schema:load already built
  # the exact state those migrations produce.
  def stamp_all_migrations(conn)
    paths = ActiveRecord::Tasks::DatabaseTasks.migrations_paths
    all = ActiveRecord::MigrationContext.new(paths).migrations.map(&:version)
    sm = conn.quote_table_name("schema_migrations")
    existing = conn.select_values("SELECT version FROM #{sm}").map(&:to_i)
    missing = (all - existing).sort
    if missing.empty?
      puts "[schema] schema_migrations already complete (#{existing.size} versions)."
      return
    end
    values = missing.map { |v| "(#{conn.quote(v.to_s)})" }.join(", ")
    conn.execute("INSERT INTO #{sm} (version) VALUES #{values}")
    puts "[schema] Stamped #{missing.size} engine/primary migration versions " \
         "(schema_migrations now #{existing.size + missing.size})."
  end

  def load_portable_schema(target_config)
    require "tempfile"
    schema_file = ActiveRecord::Tasks::DatabaseTasks.schema_dump_path(target_config)
    schema_file ||= Rails.root.join("db", "schema.rb").to_s
    content = File.read(schema_file)
    content = content.gsub(
      /json_extract\(\s*([A-Za-z_][A-Za-z0-9_]*)\s*,\s*'\$\.([^']+)'\s*\)/,
      '(\1 ->> \'\2\')'
    )
    # PostgreSQL `text`/`binary` have no byte limit; SQLite/MySQL-style limits
    # (e.g. 4294967295 for LONGTEXT) exceed Postgres's max and raise on load.
    content = content.gsub(/(\bt\.(?:text|binary)\b[^\n]*?),\s*limit:\s*\d+/, '\1')

    Tempfile.create([ "schema", ".rb" ]) do |f|
      f.write(content)
      f.flush
      ActiveRecord::Tasks::DatabaseTasks.load_schema(target_config, :ruby, f.path)
    end
  end

  # Build a non-secret description of the target (host/db without password).
  def safe_target_desc(db_config)
    cfg = db_config.configuration_hash
    if cfg[:host]
      db = cfg[:database]
      "#{cfg[:host]}:#{cfg[:port] || 5432}/#{db}"
    elsif cfg[:url]
      begin
        u = URI.parse(cfg[:url])
        "#{u.host}:#{u.port || 5432}#{u.path}"
      rescue StandardError
        "(postgresql)"
      end
    else
      cfg[:database] || "(postgresql)"
    end
  end
end
