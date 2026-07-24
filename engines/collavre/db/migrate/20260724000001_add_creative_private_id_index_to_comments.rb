class AddCreativePrivateIdIndexToComments < ActiveRecord::Migration[8.1]
  # Every unread/badge count is "comments of this creative, public only, newer
  # than a watermark" — `WHERE creative_id = ? AND private = false [AND id > ?]`.
  # index_comments_on_creative_id_and_id can serve the creative filter and the
  # id ordering but not the private filter, so the planner still had to visit
  # every row of a busy creative to discard private ones. Putting `private`
  # between the two makes the whole predicate index-only.
  #
  # Deliberately NOT a `WHERE private = false` partial index: Rails' SQLite
  # adapter renders `where(private: false)` as `private = 0`, which does not
  # match a predicate recorded as `private = false`, so SQLite (dev, test and
  # the desktop build) would create the index and then never use it. A plain
  # three-column index is used by both adapters and dumps identically.
  #
  # index_comments_on_creative_id_and_id stays: `ORDER BY id` paging cannot use
  # this index without skipping the leading private column.
  disable_ddl_transaction!

  # Explicit up/down: `change` auto-reverses add_index by forwarding every option
  # (including if_not_exists:) to remove_index, which rejects it and fails rollback.
  def up
    add_index :comments, [ :creative_id, :private, :id ],
              name: "index_comments_on_creative_id_and_private_and_id",
              algorithm: concurrent_algorithm,
              if_not_exists: true
  end

  def down
    remove_index :comments,
                 name: "index_comments_on_creative_id_and_private_and_id",
                 algorithm: concurrent_algorithm,
                 if_exists: true
  end

  private

  def concurrent_algorithm
    :concurrently if connection.adapter_name.match?(/postgres/i)
  end
end
