class AddAsyncCommentNotificationState < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def up
    add_column :comments, :notification_key, :string unless column_exists?(:comments, :notification_key)
    unless column_exists?(:comments, :notification_revision)
      add_column :comments, :notification_revision, :integer, default: 0, null: false
    end

    create_table :comment_notification_deliveries, if_not_exists: true do |t|
      t.string :delivery_key, null: false
      t.bigint :inbox_comment_id, null: false
      t.bigint :recipient_id, null: false
      t.text :message, null: false
      t.text :link
      t.string :push_claim_token
      t.datetime :push_claimed_at
      t.datetime :push_enqueued_at
      t.timestamps
    end

    add_index :comments,
              :notification_key,
              unique: true,
              where: "notification_key IS NOT NULL",
              algorithm: concurrent_algorithm,
              if_not_exists: true

    add_index :comment_notification_deliveries,
              :delivery_key,
              unique: true,
              algorithm: concurrent_algorithm,
              if_not_exists: true
    add_index :comment_notification_deliveries,
              [ :push_enqueued_at, :push_claimed_at ],
              name: "index_comment_notification_deliveries_pending",
              algorithm: concurrent_algorithm,
              if_not_exists: true
  end

  def down
    remove_index :comment_notification_deliveries,
                 name: "index_comment_notification_deliveries_pending",
                 algorithm: concurrent_algorithm,
                 if_exists: true
    remove_index :comment_notification_deliveries,
                 :delivery_key,
                 algorithm: concurrent_algorithm,
                 if_exists: true
    remove_index :comments,
                 :notification_key,
                 algorithm: concurrent_algorithm,
                 if_exists: true
    drop_table :comment_notification_deliveries, if_exists: true
    remove_column :comments, :notification_revision if column_exists?(:comments, :notification_revision)
    remove_column :comments, :notification_key if column_exists?(:comments, :notification_key)
  end

  private

  def concurrent_algorithm
    :concurrently if connection.adapter_name.match?(/postgres/i)
  end
end
