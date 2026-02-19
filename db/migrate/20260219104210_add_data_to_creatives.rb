class AddDataToCreatives < ActiveRecord::Migration[8.1]
  def change
    add_column :creatives, :data, :jsonb, default: {}, null: false
    add_index :creatives, :data, using: :gin
  end
end
