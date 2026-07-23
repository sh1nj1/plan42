class AddCreativeIdIndexToComments < ActiveRecord::Migration[8.1]
  # The chat timeline now orders by comments.id (not created_at) to survive
  # cross-process clock skew. A composite index on [creative_id, id] lets the DB
  # satisfy the per-creative filter and the id-ordered LIMIT/range paging from
  # the index, instead of scanning creative_id then sorting by id.
  def change
    unless index_exists?(:comments, [ :creative_id, :id ])
      add_index :comments, [ :creative_id, :id ], name: "index_comments_on_creative_id_and_id"
    end
  end
end
