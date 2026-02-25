# frozen_string_literal: true

class CreateCommentVersions < ActiveRecord::Migration[8.0]
  def change
    create_table :comment_versions do |t|
      t.references :comment, null: false, foreign_key: true
      t.text :content, null: false
      t.integer :version_number, null: false
      t.references :review_comment, foreign_key: { to_table: :comments }
      t.timestamps
    end
    add_index :comment_versions, %i[comment_id version_number], unique: true
  end
end
