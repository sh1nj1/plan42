class AddJustifyCreativeDescriptionsToUsers < ActiveRecord::Migration[8.1]
  def change
    add_column :users, :justify_creative_descriptions, :boolean, default: true, null: false
  end
end
