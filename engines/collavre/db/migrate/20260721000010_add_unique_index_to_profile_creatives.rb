class AddUniqueIndexToProfileCreatives < ActiveRecord::Migration[8.1]
  # Enforce one profile creative per user at the DB level so a concurrent
  # SELECT-then-INSERT race can never leave a split-brain duplicate — a second
  # profile row the Creative tree/UI can edit while execution keeps reading the
  # oldest one. Deterministic order(:id) lookups only *converged* on a duplicate;
  # this *prevents* it.
  #
  # The discriminator lives in the `data` json column, but a partial unique
  # index must NOT reference a JSON expression (`data->>'kind'`): schema.rb is
  # dumped from the SQLite dev DB, where the predicate serializes to
  # `json_extract(data, '$.kind')`, which is not a PostgreSQL function, so
  # `db:schema:load` crashes on production. (An earlier revision used the JSON
  # expression and rationalized it as Postgres-IMMUTABLE; that missed the
  # SQLite-dump path this project documents in docs/engine_development.md.)
  # Instead promote the discriminator to a real `kind` column kept in sync from
  # `data` by Collavre::IndexedJsonColumns, and index that plain column — it
  # dumps identically on both adapters. Mirrors the reference promote-and-reindex
  # migration 20260702000005_promote_channel_config_index_columns.
  #
  # The `kind` column itself is added earlier by 20260720235959, BEFORE the
  # profile backfills (20260721000000/000001) run, so those model saves don't
  # raise on a missing column. By the time this migration runs, every profile
  # row (pre-existing and backfilled) already carries kind = 'profile'.
  def up
    collapse_duplicate_profiles!

    add_index :creatives, :user_id,
              unique: true,
              where: "kind = 'profile'",
              name: "index_creatives_on_user_id_profile_unique"
  end

  def down
    remove_index :creatives, name: "index_creatives_on_user_id_profile_unique"
  end

  private

  # Keep the oldest profile per user (matches profile_for's order(:id) selection)
  # and remove any race-created duplicates, which are freshly-created-and-unused
  # by definition. Runs after the `kind` column is backfilled, so it groups on
  # the plain column.
  #
  # Destroy through the model, not delete_all: every Creative gets a `Main` topic
  # via after_create :create_main_topic, and topics.creative_id is a
  # non-cascading foreign key. delete_all would bypass has_many :topics,
  # dependent: :destroy — on Postgres the FK rejects the DELETE, and on SQLite
  # (FKs often off) it leaves orphaned topic rows. destroy cascades to the Main
  # topic (and its own dependents), which for a fresh duplicate are empty.
  def collapse_duplicate_profiles!
    dup_user_ids = Collavre::Creative
                   .where(kind: "profile")
                   .group(:user_id)
                   .having("COUNT(*) > 1")
                   .pluck(:user_id)

    dup_user_ids.each do |uid|
      duplicates = Collavre::Creative
                   .where(kind: "profile")
                   .where(user_id: uid)
                   .order(:id)
                   .to_a
      duplicates.drop(1).each(&:destroy!)
    end
  end
end
