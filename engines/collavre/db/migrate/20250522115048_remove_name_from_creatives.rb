class RemoveNameFromCreatives < ActiveRecord::Migration[7.0]
  def change
    remove_column :creatives, :name, :string
  end
end
