class CreateChannels < ActiveRecord::Migration[8.1]
  def change
    postgres = connection.adapter_name == "PostgreSQL"

    create_table :channels do |t|
      t.string :type, null: false
      t.references :topic, null: false, foreign_key: { to_table: :topics }, index: true
      if postgres
        t.jsonb :config, null: false, default: {}
      else
        t.json :config, null: false, default: {}
      end
      t.integer :state, null: false, default: 0
      t.string :latest_label
      t.string :latest_link
      t.datetime :last_event_at
      t.timestamps
    end

    if postgres
      add_index :channels, :config, using: :gin
      add_index :channels, :type
    else
      add_index :channels, :type
    end
  end
end
