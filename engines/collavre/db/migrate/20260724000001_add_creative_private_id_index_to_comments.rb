class AddCreativePrivateIdIndexToComments < ActiveRecord::Migration[8.1]
  # Every unread/badge count is "comments of this creative, public only, newer
  # than a watermark" — `WHERE creative_id = ? AND private = false [AND id > ?]`.
  # index_comments_on_creative_id_and_id can serve the creative filter and the
  # id ordering but not the private filter, so the planner still had to visit
  # every row of a busy creative to discard private ones.
  #
  # Production PostgreSQL gets the smallest useful structure: a partial index
  # over public rows only. SQLite renders `where(private: false)` as
  # `private = 0`, which does not use a partial predicate recorded as
  # `private = false`, so dev, test, and desktop use an equivalent three-column
  # index instead.
  #
  # index_comments_on_creative_id_and_id stays: paging does not include the
  # public-only predicate, and SQLite cannot skip the fallback index's leading
  # `private` column for a plain `ORDER BY id` query.
  disable_ddl_transaction!

  # Explicit up/down: `change` auto-reverses add_index by forwarding every option
  # (including if_not_exists:) to remove_index, which rejects it and fails rollback.
  def up
    options = { name: index_name, if_not_exists: true }

    if postgresql?
      options.merge!(where: "private = false", algorithm: :concurrently)
      add_index :comments, [ :creative_id, :id ], **options
    else
      add_index :comments, [ :creative_id, :private, :id ], **options
    end
  end

  def down
    options = { name: index_name, algorithm: concurrent_algorithm, if_exists: true }
    remove_index :comments, **options
  end

  private

  def index_name
    "index_comments_on_creative_id_and_private_and_id"
  end

  def postgresql?
    connection.adapter_name.match?(/postgres/i)
  end

  def concurrent_algorithm
    :concurrently if postgresql?
  end
end
