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
    add_index :comment_read_pointers, %i[user_id creative_id], unique: true,
              where: "topic_id IS NULL", name: "index_comment_read_pointers_on_legacy_pointer"
  end

  def down
    remove_index :comment_read_pointers, name: "index_comment_read_pointers_on_legacy_pointer"
    remove_index :comment_read_pointers, name: "index_comment_read_pointers_on_user_creative_and_topic"
    consolidate_topic_watermarks
    execute "DELETE FROM comment_read_pointers WHERE topic_id IS NOT NULL"
    remove_reference :comment_read_pointers, :topic, foreign_key: true
    add_index :comment_read_pointers, %i[user_id creative_id], unique: true
  end

  private

  def consolidate_topic_watermarks
    create_missing_legacy_pointers

    execute <<~SQL.squish
      UPDATE comment_read_pointers AS legacy_pointers
      SET last_read_comment_id = (
        SELECT MIN(COALESCE(topic_pointers.last_read_comment_id, 0))
        FROM comment_read_pointers AS topic_pointers
        WHERE topic_pointers.user_id = legacy_pointers.user_id
          AND topic_pointers.creative_id = legacy_pointers.creative_id
          AND topic_pointers.topic_id IS NOT NULL
      )
      WHERE legacy_pointers.topic_id IS NULL
        AND COALESCE(legacy_pointers.last_read_comment_id, 0) > COALESCE((
          SELECT MIN(COALESCE(topic_pointers.last_read_comment_id, 0))
          FROM comment_read_pointers AS topic_pointers
          WHERE topic_pointers.user_id = legacy_pointers.user_id
            AND topic_pointers.creative_id = legacy_pointers.creative_id
            AND topic_pointers.topic_id IS NOT NULL
        ), 0)
    SQL
  end

  def create_missing_legacy_pointers
    execute <<~SQL.squish
      INSERT INTO comment_read_pointers (user_id, creative_id, last_read_comment_id, created_at, updated_at)
      SELECT topic_pointers.user_id, topic_pointers.creative_id, MIN(COALESCE(topic_pointers.last_read_comment_id, 0)), CURRENT_TIMESTAMP, CURRENT_TIMESTAMP
      FROM comment_read_pointers AS topic_pointers
      LEFT JOIN comment_read_pointers AS legacy_pointers ON legacy_pointers.user_id = topic_pointers.user_id AND legacy_pointers.creative_id = topic_pointers.creative_id AND legacy_pointers.topic_id IS NULL
      WHERE topic_pointers.topic_id IS NOT NULL AND legacy_pointers.id IS NULL
      GROUP BY topic_pointers.user_id, topic_pointers.creative_id
    SQL
  end
end
