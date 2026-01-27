class CreateTags < ActiveRecord::Migration[7.0]
  def change
    create_table :tags do |t|
      t.references :taggable, polymorphic: true, null: false
      t.integer :creative_id, null: false
      t.timestamps
    end
  end
end
