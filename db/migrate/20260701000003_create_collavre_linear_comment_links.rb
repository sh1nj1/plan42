class CreateCollavreLinearCommentLinks < ActiveRecord::Migration[8.0]
  def change
    create_table :linear_comment_links do |t|
      t.integer :comment_id, null: false
      t.string :linear_comment_id, null: false
      t.references :issue_link, null: false, foreign_key: { to_table: :linear_issue_links }
      # Linear-side `updatedAt` of the comment version we last synced. Lets the
      # inbound applier ignore our own (possibly stale) echoes by timestamp
      # instead of comparing against the mutable local body.
      t.datetime :remote_updated_at
      t.timestamps
    end

    add_index :linear_comment_links, :comment_id, unique: true
    add_index :linear_comment_links, :linear_comment_id, unique: true
  end
end
