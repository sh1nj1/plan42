class AddSharedByToCreativeShares < ActiveRecord::Migration[7.1]
  def change
    add_reference :creative_shares, :shared_by, foreign_key: { to_table: :users, on_delete: :nullify }

    reversible do |dir|
      dir.up do
        CreativeShare.reset_column_information
        CreativeShare.includes(:creative).find_each do |share|
          share.update_column(:shared_by_id, share.creative.user_id)
        end
      end
    end
  end
end
