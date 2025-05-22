class AddParentIdToCreatives < ActiveRecord::Migration[6.0]
  def change
    add_reference :creatives, :parent, foreign_key: { to_table: :creatives }, index: true
  end
end
