class BackfillProfileDescriptions < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def up
    Collavre::User.find_each(batch_size: 200) do |user|
      user.sync_profile_system_prompt!
    rescue => e
      Rails.logger.error("[BackfillProfileDescriptions] user #{user.id}: #{e.message}")
    end
  end

  def down
    # No-op: descriptions are safe to keep.
  end
end
