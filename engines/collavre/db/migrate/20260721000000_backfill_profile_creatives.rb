class BackfillProfileCreatives < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def up
    Collavre::User.find_each(batch_size: 200) do |user|
      Collavre::Creative.profile_for(user)
    rescue => e
      Rails.logger.error("[BackfillProfileCreatives] user #{user.id}: #{e.message}")
    end
  end

  def down
    # No-op: profiles are idempotent and safe to keep.
  end
end
