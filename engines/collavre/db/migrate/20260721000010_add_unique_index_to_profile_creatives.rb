class AddUniqueIndexToProfileCreatives < ActiveRecord::Migration[8.1]
  # Enforce one profile creative per user at the DB level so a concurrent
  # SELECT-then-INSERT race can never leave a split-brain duplicate — a second
  # profile row the Creative tree/UI can edit while execution keeps reading the
  # oldest one. Deterministic order(:id) lookups only *converged* on a duplicate;
  # this *prevents* it.
  #
  # The discriminator lives in the `data` json column. `data->>'kind'` compiles
  # to json_object_field_text, which is IMMUTABLE on Postgres (provolatile = i,
  # verified on pg14 and pg16), so a partial-unique index predicate on it is
  # accepted at schema load — the `postgres_schema_load` CI job proves it. This
  # corrects an earlier assumption that `->>` was STABLE and the index therefore
  # impossible.
  def up
    collapse_duplicate_profiles!

    add_index :creatives, :user_id,
              unique: true,
              where: "data->>'kind' = 'profile'",
              name: "index_creatives_on_user_id_profile_unique"
  end

  def down
    remove_index :creatives, name: "index_creatives_on_user_id_profile_unique"
  end

  private

  # Keep the oldest profile per user (matches profile_for's order(:id) selection)
  # and remove any race-created duplicates, which are freshly-created-and-unused
  # by definition. Portable across sqlite/pg — uses the same data->>'kind' scope.
  #
  # Destroy through the model, not delete_all: every Creative gets a `Main` topic
  # via after_create :create_main_topic, and topics.creative_id is a
  # non-cascading foreign key. delete_all would bypass has_many :topics,
  # dependent: :destroy — on Postgres the FK rejects the DELETE, and on SQLite
  # (FKs often off) it leaves orphaned topic rows. destroy cascades to the Main
  # topic (and its own dependents), which for a fresh duplicate are empty.
  def collapse_duplicate_profiles!
    dup_user_ids = Collavre::Creative
                   .where("data->>'kind' = ?", "profile")
                   .group(:user_id)
                   .having("COUNT(*) > 1")
                   .pluck(:user_id)

    dup_user_ids.each do |uid|
      duplicates = Collavre::Creative
                   .where("data->>'kind' = ?", "profile")
                   .where(user_id: uid)
                   .order(:id)
                   .to_a
      duplicates.drop(1).each(&:destroy!)
    end
  end
end
