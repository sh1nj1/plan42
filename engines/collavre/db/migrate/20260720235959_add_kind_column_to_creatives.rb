class AddKindColumnToCreatives < ActiveRecord::Migration[8.1]
  # Promote the `kind` discriminator (stored in the `data` json column) to a
  # real column. The unique index on it is added later by
  # 20260721000010_add_unique_index_to_profile_creatives.
  #
  # WHY this runs BEFORE the profile backfills (20260721000000/000001):
  # Collavre::IndexedJsonColumns installs a before_save that re-derives every
  # promoted column from `data` on EVERY Creative save (`self["kind"] = ...`).
  # The backfills save Creatives through the full model, so on an upgrade from
  # main the column must already exist — otherwise each save raises
  # ActiveModel::MissingAttributeError, the backfill's rescue swallows it, and
  # the migration "succeeds" while creating no profiles at all.
  #
  # Idempotent: a fresh install loads schema.rb (column already present) and
  # never runs migrations, but a machine that applied an earlier revision of
  # this PR may already have the column, so guard the add.
  def up
    unless column_exists?(:creatives, :kind)
      add_column :creatives, :kind, :string
    end

    # Any Creative model already loaded in this migrate run cached its columns
    # before `kind` existed; refresh so the backfills' before_save can write it.
    Collavre::Creative.reset_column_information

    if connection.adapter_name == "PostgreSQL"
      execute "UPDATE creatives SET kind = data->>'kind'"
    else
      execute "UPDATE creatives SET kind = json_extract(data, '$.kind')"
    end
  end

  def down
    remove_column :creatives, :kind
  end
end
