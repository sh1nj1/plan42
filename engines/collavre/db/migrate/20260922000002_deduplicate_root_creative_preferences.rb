class DeduplicateRootCreativePreferences < ActiveRecord::Migration[8.0]
  # Keep data cleanup independent of future application callbacks/validations.
  class Preference < ActiveRecord::Base
    self.table_name = "user_creative_preferences"
  end

  def up
    # Rails holds this lock through cleanup in the DDL transaction.
    if connection.adapter_name == "PostgreSQL"
      execute "LOCK TABLE user_creative_preferences IN ACCESS EXCLUSIVE MODE"
    end

    merge_duplicate_roots
    add_index :user_creative_preferences, :user_id, unique: true,
      where: "creative_id IS NULL",
      name: "index_user_creative_preferences_on_user_id_root_unique", if_not_exists: true
  end

  def down
    remove_index :user_creative_preferences,
      name: "index_user_creative_preferences_on_user_id_root_unique", if_exists: true
    # Removed duplicate rows cannot be reconstructed.
  end

  private

  def merge_duplicate_roots
    roots = Preference.where(creative_id: nil)
    keeper_ids = roots.group(:user_id).having("COUNT(*) > 1").select("MIN(id)")
    roots.where(id: keeper_ids).find_each do |keeper|
      duplicates = roots.where(user_id: keeper.user_id).order(:id).to_a
      state = duplicates.each_with_object({}) { |record, merged| merged.merge!(record.expanded_status || {}) }
      keeper.update_columns(expanded_status: state)
      Preference.where(id: duplicates.drop(1).map(&:id)).delete_all
    end
  end
end
