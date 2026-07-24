class AddArchivedAtToCreativesAndTopics < ActiveRecord::Migration[8.0]
  def change
    add_column :creatives, :archived_at, :datetime
    add_column :topics, :archived_at, :datetime

    add_index :creatives, :archived_at, where: "archived_at IS NOT NULL", name: "index_creatives_on_archived_at"
    add_index :topics, :archived_at, where: "archived_at IS NOT NULL", name: "index_topics_on_archived_at"
  end
end
