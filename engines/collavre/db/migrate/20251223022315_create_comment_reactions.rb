class CreateCommentReactions < ActiveRecord::Migration[7.1]
  def change
    create_table :comment_reactions do |t|
      t.references :comment, null: false, foreign_key: true
      t.references :user, null: false, foreign_key: true
      t.string :emoji, null: false

      t.timestamps
    end

    add_index :comment_reactions, [ :comment_id, :user_id, :emoji ], unique: true
  end
end
