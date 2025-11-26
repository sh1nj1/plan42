class MoveCommentsFromLinkedCreativesToOrigins < ActiveRecord::Migration[8.1]
  def up
    say_with_time "Reassigning comments from linked creatives to their origins" do
      execute <<~SQL.squish
        UPDATE comments
        SET creative_id = creatives.origin_id
        FROM creatives
        WHERE comments.creative_id = creatives.id
          AND creatives.origin_id IS NOT NULL
          AND comments.creative_id <> creatives.origin_id
      SQL
    end
  end

  def down
    raise ActiveRecord::IrreversibleMigration
  end
end
