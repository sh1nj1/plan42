class CreateUserNotices < ActiveRecord::Migration[8.0]
  def change
    create_table :user_notices do |t|
      t.bigint :user_id, null: false
      t.string :notice_key, null: false
      t.string :status, null: false, default: "pending"
      t.datetime :snoozed_until
      t.datetime :completed_at
      t.timestamps
    end
    add_index :user_notices, [ :user_id, :notice_key ], unique: true
    add_foreign_key :user_notices, :users, on_delete: :cascade
  end
end
