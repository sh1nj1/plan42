class AddCreativeIndexAndFkToTags < ActiveRecord::Migration[8.1]
  # tags.creative_id is NOT NULL and queried on every tag lookup, but only
  # label_id was indexed and there was no referential integrity to creatives.
  # Add the missing index and foreign key.
  def change
    add_index :tags, :creative_id unless index_exists?(:tags, :creative_id)
    unless foreign_key_exists?(:tags, :creatives, column: :creative_id)
      add_foreign_key :tags, :creatives, column: :creative_id
    end
  end
end
