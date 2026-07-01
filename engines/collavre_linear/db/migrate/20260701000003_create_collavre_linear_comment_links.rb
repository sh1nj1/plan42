class CreateCollavreLinearCommentLinks < ActiveRecord::Migration[8.0]
  def change
    create_table :linear_comment_links do |t|
      t.integer :comment_id, null: false
      t.string :linear_comment_id, null: false
      t.references :issue_link, null: false, foreign_key: { to_table: :linear_issue_links }
      t.timestamps
    end

    add_index :linear_comment_links, :comment_id, unique: true
    add_index :linear_comment_links, :linear_comment_id, unique: true
  end
end
