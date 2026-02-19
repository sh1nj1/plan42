class AddDataToCreatives < ActiveRecord::Migration[8.1]
  def change
    if connection.adapter_name == "PostgreSQL"
      add_column :creatives, :data, :jsonb, default: {}, null: false
      add_index :creatives, :data, using: :gin
    else
      add_column :creatives, :data, :json, default: {}, null: false
    end
  end
end
