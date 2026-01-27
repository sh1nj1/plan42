# frozen_string_literal: true

class CreateActivityLogs < ActiveRecord::Migration[7.1]
  def change
    create_table :activity_logs do |t|
      t.string :activity, null: false
      t.json :log, default: {}, null: false
      t.references :creative, foreign_key: true, null: true
      t.references :user, foreign_key: true, null: true
      t.references :comment, foreign_key: true, null: true
      t.datetime :created_at, null: false
    end

    add_index :activity_logs, :created_at
  end
end
