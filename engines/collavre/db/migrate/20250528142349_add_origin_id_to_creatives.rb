class AddOriginIdToCreatives < ActiveRecord::Migration[8.0]
  def change
    add_reference :creatives, :origin, foreign_key: { to_table: :creatives }, null: true
  end
end
