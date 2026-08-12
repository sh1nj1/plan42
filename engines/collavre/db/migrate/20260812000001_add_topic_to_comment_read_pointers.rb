class AddTopicToCommentReadPointers < ActiveRecord::Migration[8.0]
  def up
    add_reference :comment_read_pointers, :topic,
                  foreign_key: { to_table: :topics, on_delete: :cascade }, null: true
    remove_index :comment_read_pointers, column: %i[user_id creative_id]

    execute <<~SQL.squish
      INSERT INTO comment_read_pointers
        (user_id, creative_id, topic_id, last_read_comment_id, created_at, updated_at)
      SELECT pointers.user_id, pointers.creative_id, topics.id,
             pointers.last_read_comment_id, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP
      FROM comment_read_pointers AS pointers
      INNER JOIN topics ON topics.creative_id = pointers.creative_id
      WHERE pointers.topic_id IS NULL
    SQL

    add_index :comment_read_pointers, %i[user_id creative_id topic_id], unique: true,
              name: "index_comment_read_pointers_on_user_creative_and_topic"
  end

  def down
    remove_index :comment_read_pointers, name: "index_comment_read_pointers_on_user_creative_and_topic"
    execute "DELETE FROM comment_read_pointers WHERE topic_id IS NOT NULL"
    remove_reference :comment_read_pointers, :topic, foreign_key: true
    add_index :comment_read_pointers, %i[user_id creative_id], unique: true
  end
end
