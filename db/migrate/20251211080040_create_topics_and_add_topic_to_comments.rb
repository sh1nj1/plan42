class CreateTopicsAndAddTopicToComments < ActiveRecord::Migration[8.1]
  def change
    create_table :topics do |t|
      t.references :creative, null: false, foreign_key: true
      t.references :user, null: false, foreign_key: true
      t.string :name, null: false

      t.timestamps
    end

    add_index :topics, [ :creative_id, :name ], unique: true

    add_reference :comments, :topic, foreign_key: true, null: true
  end
end
