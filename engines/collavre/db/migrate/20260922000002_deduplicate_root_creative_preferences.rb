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
    # Defer the partial unique index until the prior composite-targeted writer
    # is no longer a rollout or rollback candidate. It cannot handle that conflict.
  end

  def down
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
