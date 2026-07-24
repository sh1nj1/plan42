class AddNotificationKeyToComments < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def up
    add_column :comments, :notification_key, :string unless column_exists?(:comments, :notification_key)
    unless column_exists?(:comments, :notification_revision)
      add_column :comments, :notification_revision, :integer, default: 0, null: false
    end

    add_index :comments,
              :notification_key,
              unique: true,
              where: "notification_key IS NOT NULL",
              algorithm: concurrent_algorithm,
              if_not_exists: true
  end

  def down
    remove_index :comments,
                 :notification_key,
                 algorithm: concurrent_algorithm,
                 if_exists: true
    remove_column :comments, :notification_revision if column_exists?(:comments, :notification_revision)
    remove_column :comments, :notification_key if column_exists?(:comments, :notification_key)
  end

  private

  def concurrent_algorithm
    :concurrently if connection.adapter_name.match?(/postgres/i)
  end
end
