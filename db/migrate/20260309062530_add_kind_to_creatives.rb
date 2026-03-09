class AddKindToCreatives < ActiveRecord::Migration[8.1]
  def change
    add_column :creatives, :kind, :string
    add_index :creatives, :kind
  end
end
