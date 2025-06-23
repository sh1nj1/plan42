class CreateCommentReads < ActiveRecord::Migration[8.0]
  def change
    create_table :comment_reads do |t|
      t.references :comment, null: false, foreign_key: true
      t.references :user, null: false, foreign_key: true
      t.boolean :read, null: false, default: false
      t.timestamps
    end
    add_index :comment_reads, [ :comment_id, :user_id ], unique: true
  end
end
