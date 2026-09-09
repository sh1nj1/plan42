class AddJoinedAtOrderIndexToUsers < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def up
    add_index :users, %i[created_at id],
      name: "index_users_on_created_at_and_id",
      algorithm: concurrent_algorithm,
      if_not_exists: true
  end

  def down
    remove_index :users,
      name: "index_users_on_created_at_and_id",
      algorithm: concurrent_algorithm,
      if_exists: true
  end

  private

  def concurrent_algorithm
    :concurrently if connection.adapter_name.match?(/postgres/i)
  end
end
