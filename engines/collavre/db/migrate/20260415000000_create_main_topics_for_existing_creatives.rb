class CreateMainTopicsForExistingCreatives < ActiveRecord::Migration[8.0]
  def up
    now = Time.current

    # Find creative IDs that don't already have a "Main" topic
    creative_ids_with_main = select_values("SELECT creative_id FROM topics WHERE name = 'Main'")

    if creative_ids_with_main.any?
      creatives = select_all(
        "SELECT id, user_id FROM creatives WHERE id NOT IN (#{creative_ids_with_main.join(',')})"
      )
    else
      creatives = select_all("SELECT id, user_id FROM creatives")
    end

    # Create Main topics for each creative
    creatives.each do |row|
      max_pos = select_value(
        "SELECT MAX(position) FROM topics WHERE creative_id = #{row['id']}"
      ).to_i

      execute(sanitize(
        "INSERT INTO topics (creative_id, user_id, name, position, created_at, updated_at) VALUES (?, ?, 'Main', ?, ?, ?)",
        row["id"], row["user_id"], max_pos + 1, now, now
      ))
    end

    # Migrate topic_id=nil comments to their creative's Main topic
    execute(<<~SQL)
      UPDATE comments
      SET topic_id = (
        SELECT topics.id FROM topics
        WHERE topics.creative_id = comments.creative_id
          AND topics.name = 'Main'
        LIMIT 1
      )
      WHERE comments.topic_id IS NULL
    SQL
  end

  def down
    # Set comments back to nil for Main topics
    execute(<<~SQL)
      UPDATE comments
      SET topic_id = NULL
      WHERE topic_id IN (SELECT id FROM topics WHERE name = 'Main')
    SQL

    execute("DELETE FROM topics WHERE name = 'Main'")
  end

  private

  def select_all(sql)
    ActiveRecord::Base.connection.select_all(sql)
  end

  def select_values(sql)
    ActiveRecord::Base.connection.select_values(sql)
  end

  def select_value(sql)
    ActiveRecord::Base.connection.select_value(sql)
  end

  def sanitize(*args)
    ActiveRecord::Base.sanitize_sql_array(args)
  end
end
