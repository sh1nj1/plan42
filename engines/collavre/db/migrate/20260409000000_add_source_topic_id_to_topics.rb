class AddSourceTopicIdToTopics < ActiveRecord::Migration[8.0]
  def change
    add_reference :topics, :source_topic, foreign_key: { to_table: :topics, on_delete: :nullify }, null: true
  end
end
