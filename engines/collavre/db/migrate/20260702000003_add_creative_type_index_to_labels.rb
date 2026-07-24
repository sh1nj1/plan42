class AddCreativeTypeIndexToLabels < ActiveRecord::Migration[8.1]
  # Labels are almost always fetched for a creative filtered by their kind
  # (`type`). A composite index on [creative_id, type] serves those lookups
  # far better than the standalone creative_id index alone.
  def change
    unless index_exists?(:labels, [ :creative_id, :type ])
      add_index :labels, [ :creative_id, :type ], name: "index_labels_on_creative_id_and_type"
    end
  end
end
