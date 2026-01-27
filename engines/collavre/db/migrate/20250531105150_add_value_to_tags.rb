class AddValueToTags < ActiveRecord::Migration[8.0]
  def change
    add_column :tags, :value, :string
  end
end
