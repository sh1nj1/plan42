# frozen_string_literal: true

class AddSelectedVersionIdToComments < ActiveRecord::Migration[8.1]
  def change
    add_reference :comments, :selected_version, foreign_key: { to_table: :comment_versions }, null: true
  end
end
