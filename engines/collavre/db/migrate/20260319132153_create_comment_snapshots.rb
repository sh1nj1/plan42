class CreateCommentSnapshots < ActiveRecord::Migration[8.0]
  def change
    create_table :comment_snapshots do |t|
      t.references :creative, null: false, foreign_key: true
      t.references :topic, foreign_key: true
      t.references :user, null: false, foreign_key: true
      t.string :operation, null: false
      t.json :comments_data, null: false, default: []
      t.references :result_comment, foreign_key: { to_table: :comments, on_delete: :nullify }
      t.datetime :restored_at

      t.timestamps
    end

    add_index :comment_snapshots, [ :creative_id, :operation ]
    add_index :comment_snapshots, :restored_at
  end
end
