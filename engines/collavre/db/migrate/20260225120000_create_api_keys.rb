# frozen_string_literal: true

class CreateApiKeys < ActiveRecord::Migration[8.1]
  def change
    create_table :api_keys do |t|
      t.references :user, null: false, foreign_key: true
      t.string :name, null: false
      t.string :token_digest, null: false
      t.string :token_prefix, null: false, limit: 8
      t.datetime :last_used_at
      t.datetime :expires_at
      t.timestamps
    end
    add_index :api_keys, :token_digest, unique: true
    add_index :api_keys, :token_prefix
  end
end
