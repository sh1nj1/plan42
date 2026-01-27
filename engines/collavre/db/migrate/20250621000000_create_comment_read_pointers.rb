class CreateCommentReadPointers < ActiveRecord::Migration[8.0]
  def change
    create_table :comment_read_pointers do |t|
      t.references :user, null: false, foreign_key: true
      t.references :creative, null: false, foreign_key: true
      t.integer :last_read_comment_id
      t.timestamps
    end
    add_index :comment_read_pointers, [ :user_id, :creative_id ], unique: true
  end
end
