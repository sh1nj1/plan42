class PopulateInheritedShares < ActiveRecord::Migration[8.1]
  def up
    # Get all direct shares (inherited = false)
    direct_shares = execute(<<-SQL).to_a
      SELECT id, creative_id, user_id, permission
      FROM creative_shares
      WHERE inherited = 0
    SQL

    say "Found #{direct_shares.size} direct shares to process"

    total_created = 0
    direct_shares.each do |share|
      creative_id = share["creative_id"]
      user_id = share["user_id"]
      permission = share["permission"]

      # Get all descendants (real hierarchy)
      real_descendants = execute(<<-SQL).to_a
        SELECT descendant_id
        FROM creative_hierarchies
        WHERE ancestor_id = #{creative_id}
          AND descendant_id != #{creative_id}
      SQL

      # Get all virtual descendants
      virtual_descendants = execute(<<-SQL).to_a
        SELECT descendant_id
        FROM virtual_creative_hierarchies
        WHERE ancestor_id = #{creative_id}
      SQL

      descendant_ids = (real_descendants + virtual_descendants)
        .map { |d| d["descendant_id"] }
        .uniq

      next if descendant_ids.empty?

      now = Time.current.utc.iso8601
      descendant_ids.each do |descendant_id|
        # Skip if share already exists for this user/creative combination
        # Handle NULL user_id (public shares)
        user_condition = user_id.nil? ? "user_id IS NULL" : "user_id = #{user_id}"
        existing = execute(<<-SQL).first
          SELECT id FROM creative_shares
          WHERE creative_id = #{descendant_id} AND #{user_condition}
        SQL

        next if existing

        user_value = user_id.nil? ? "NULL" : user_id
        execute(<<-SQL)
          INSERT INTO creative_shares (creative_id, user_id, permission, inherited, created_at, updated_at)
          VALUES (#{descendant_id}, #{user_value}, #{permission}, 1, '#{now}', '#{now}')
        SQL
        total_created += 1
      end
    end

    say "Created #{total_created} inherited shares"
  end

  def down
    # Remove all inherited shares
    execute("DELETE FROM creative_shares WHERE inherited = 1")
  end
end
