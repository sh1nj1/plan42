class AddActorLookupIndexToCreativeChangeSets < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def up
    add_index :creative_change_sets, [ :user_id, :status, :actor_kind ],
      name: "index_creative_change_sets_on_actor_lookup", algorithm: concurrent_algorithm
  end

  def down
    remove_index :creative_change_sets,
      name: "index_creative_change_sets_on_actor_lookup", algorithm: concurrent_algorithm
  end

  private

  def concurrent_algorithm
    :concurrently if connection.adapter_name.match?(/postgres/i)
  end
end
