class AddCreativeIdIndexToComments < ActiveRecord::Migration[8.1]
  # The chat timeline now orders by comments.id (not created_at) to survive
  # cross-process clock skew. A composite index on [creative_id, id] lets the DB
  # satisfy the per-creative filter and the id-ordered LIMIT/range paging from
  # the index, instead of scanning creative_id then sorting by id.
  #
  # Built CONCURRENTLY on PostgreSQL so the deploy never takes a write-blocking
  # lock on the hot comments table while the index builds. Requires running
  # outside a transaction. SQLite (dev/test) has no concurrent algorithm, so we
  # omit it there; if_not_exists keeps the build idempotent on both.
  disable_ddl_transaction!

  # Explicit up/down: `change` auto-reverses add_index by forwarding every option
  # (including if_not_exists:) to remove_index, which rejects it and fails rollback.
  def up
    add_index :comments, [ :creative_id, :id ],
              name: "index_comments_on_creative_id_and_id",
              algorithm: concurrent_algorithm,
              if_not_exists: true
  end

  def down
    remove_index :comments,
                 name: "index_comments_on_creative_id_and_id",
                 algorithm: concurrent_algorithm,
                 if_exists: true
  end

  private

  def concurrent_algorithm
    :concurrently if connection.adapter_name.match?(/postgres/i)
  end
end
