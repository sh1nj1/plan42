require "securerandom"

class BackfillPublicCreativeIds < ActiveRecord::Migration[8.0]
  class Creative < ActiveRecord::Base
    self.table_name = "creatives"
  end

  class CreativeShare < ActiveRecord::Base
    self.table_name = "creative_shares"
  end

  def up
    Creative.reset_column_information
    public_grants = CreativeShare.where(user_id: nil).where.not(permission: 0).select(:creative_id)
    Creative.where(id: public_grants, public_id: nil).in_batches(of: 500) do |batch|
      # Explicitly public legacy rows may later become active roots. Preserve concurrent publications.
      batch.pluck(:id).each do |id|
        Creative.where(id: id, public_id: nil).update_all(public_id: SecureRandom.alphanumeric(10))
      end
    end
  end

  def down
    # Public addresses must remain stable after publication.
  end
end
