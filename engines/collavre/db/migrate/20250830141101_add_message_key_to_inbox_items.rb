class AddMessageKeyToInboxItems < ActiveRecord::Migration[8.0]
  def change
    add_column :inbox_items, :message_key, :string
    add_column :inbox_items, :message_params, :jsonb, default: {}, null: false
  end
end
