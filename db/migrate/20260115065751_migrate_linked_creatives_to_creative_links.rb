class MigrateLinkedCreativesToCreativeLinks < ActiveRecord::Migration[8.1]
  def up
    # Migrate existing Linked Creatives (with origin_id) to creative_links
    linked_creatives = execute(<<-SQL).to_a
      SELECT id, parent_id, origin_id, user_id, sequence, created_at
      FROM creatives
      WHERE origin_id IS NOT NULL AND parent_id IS NOT NULL
    SQL

    linked_creatives.each do |linked|
      linked_id = linked["id"]

      # Check if link already exists
      existing = execute(<<-SQL).first
        SELECT id FROM creative_links
        WHERE parent_id = #{linked["parent_id"]} AND origin_id = #{linked["origin_id"]}
      SQL

      unless existing
        # Create creative_link
        execute(<<-SQL)
          INSERT INTO creative_links (parent_id, origin_id, created_by_id, sequence, created_at, updated_at)
          VALUES (
            #{linked["parent_id"]},
            #{linked["origin_id"]},
            #{linked["user_id"]},
            #{linked["sequence"] || 0},
            '#{linked["created_at"]}',
            '#{Time.current.utc.iso8601}'
          )
        SQL
      end

      # Reassign children to the origin (they should belong to origin, not the linked creative)
      execute("UPDATE creatives SET parent_id = #{linked["origin_id"]} WHERE parent_id = #{linked_id}")

      # Delete dependent records that reference this creative
      execute("DELETE FROM comments WHERE creative_id = #{linked_id}")
      execute("DELETE FROM comment_read_pointers WHERE creative_id = #{linked_id}")
      execute("DELETE FROM tags WHERE creative_id = #{linked_id}")
      execute("DELETE FROM creative_shares WHERE creative_id = #{linked_id}")
      execute("DELETE FROM creative_expanded_states WHERE creative_id = #{linked_id}")
      execute("DELETE FROM invitations WHERE creative_id = #{linked_id}")
      execute("DELETE FROM github_repository_links WHERE creative_id = #{linked_id}")
      execute("DELETE FROM notion_page_links WHERE creative_id = #{linked_id}")
      execute("DELETE FROM notion_block_links WHERE creative_id = #{linked_id}")
      execute("DELETE FROM topics WHERE creative_id = #{linked_id}")
      execute("DELETE FROM mcp_tools WHERE creative_id = #{linked_id}")
      execute("DELETE FROM activity_logs WHERE creative_id = #{linked_id}")
      execute("DELETE FROM creative_hierarchies WHERE ancestor_id = #{linked_id} OR descendant_id = #{linked_id}")

      # Delete the linked creative
      execute("DELETE FROM creatives WHERE id = #{linked_id}")
    end

    say "Migrated #{linked_creatives.size} linked creatives to creative_links"

    # Rebuild virtual hierarchies
    rebuild_virtual_hierarchies
  end

  def down
    # This migration is not easily reversible
    # The deleted linked creatives cannot be restored
    raise ActiveRecord::IrreversibleMigration
  end

  private

  def rebuild_virtual_hierarchies
    # Clear existing virtual hierarchies
    execute("DELETE FROM virtual_creative_hierarchies")

    # Get all creative_links
    links = execute("SELECT id, parent_id, origin_id FROM creative_links").to_a

    links.each do |link|
      build_virtual_hierarchy_for_link(link)
    end

    count = execute("SELECT COUNT(*) as cnt FROM virtual_creative_hierarchies").first["cnt"]
    say "Built #{count} virtual hierarchy entries for #{links.size} creative_links"
  end

  def build_virtual_hierarchy_for_link(link)
    parent_id = link["parent_id"]
    origin_id = link["origin_id"]
    link_id = link["id"]

    # Get parent's ancestors (including parent itself)
    parent_ancestors = execute(<<-SQL).to_a
      SELECT ancestor_id, generations
      FROM creative_hierarchies
      WHERE descendant_id = #{parent_id}
    SQL
    parent_ancestors << { "ancestor_id" => parent_id, "generations" => 0 }

    # Get virtual ancestors of parent (for nested links)
    virtual_ancestors = execute(<<-SQL).to_a
      SELECT ancestor_id, generations
      FROM virtual_creative_hierarchies
      WHERE descendant_id = #{parent_id}
    SQL

    # Merge virtual ancestors into parent_ancestors
    ancestor_map = parent_ancestors.each_with_object({}) do |a, h|
      h[a["ancestor_id"]] = a["generations"]
    end
    virtual_ancestors.each do |va|
      aid = va["ancestor_id"]
      gen = va["generations"]
      ancestor_map[aid] = gen unless ancestor_map.key?(aid) && ancestor_map[aid] <= gen
    end

    # Get origin's descendants (including origin itself)
    origin_descendants = execute(<<-SQL).to_a
      SELECT descendant_id, generations
      FROM creative_hierarchies
      WHERE ancestor_id = #{origin_id}
    SQL
    origin_descendants << { "descendant_id" => origin_id, "generations" => 0 }

    # Create virtual hierarchy entries
    now = Time.current.utc.iso8601
    ancestor_map.each do |ancestor_id, gen_to_parent|
      origin_descendants.each do |desc|
        descendant_id = desc["descendant_id"]
        gen_from_origin = desc["generations"]
        total_generations = gen_to_parent + 1 + gen_from_origin

        execute(<<-SQL)
          INSERT INTO virtual_creative_hierarchies (ancestor_id, descendant_id, generations, creative_link_id, created_at, updated_at)
          VALUES (#{ancestor_id}, #{descendant_id}, #{total_generations}, #{link_id}, '#{now}', '#{now}')
          ON CONFLICT (ancestor_id, descendant_id) DO NOTHING
        SQL
      end
    end
  end
end
