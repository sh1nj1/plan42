class AddCreativeCreatedAtIndexToComments < ActiveRecord::Migration[8.1]
  # Comments are rendered per creative in chronological order. A composite
  # index on [creative_id, created_at] lets the DB satisfy both the filter and
  # the sort from the index instead of filtering on creative_id then sorting.
  def change
    unless index_exists?(:comments, [ :creative_id, :created_at ])
      add_index :comments, [ :creative_id, :created_at ], name: "index_comments_on_creative_id_and_created_at"
    end
  end
end
