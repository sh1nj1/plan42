# frozen_string_literal: true

class AddSystemKindToTopics < ActiveRecord::Migration[8.1]
  def change
    add_column :topics, :system_kind, :string
    add_index :topics, %i[creative_id system_kind], unique: true
  end
end
