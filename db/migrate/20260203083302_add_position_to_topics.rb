class AddPositionToTopics < ActiveRecord::Migration[8.1]
  def change
    add_column :topics, :position, :integer, default: 0, null: false

    # Set position based on created_at order for existing topics
    reversible do |dir|
      dir.up do
        # Group topics by creative_id and set position based on created_at order
        execute <<-SQL
          UPDATE topics
          SET position = (
            SELECT COUNT(*)
            FROM topics t2
            WHERE t2.creative_id = topics.creative_id
            AND t2.created_at < topics.created_at
          )
        SQL
      end
    end

    add_index :topics, [ :creative_id, :position ]
  end
end
