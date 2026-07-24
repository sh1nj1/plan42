# frozen_string_literal: true

class RemoveDisplaySettingsFromUsers < ActiveRecord::Migration[8.0]
  def change
    remove_column :users, :display_level, :integer, default: 6, null: false
    remove_column :users, :completion_mark, :string, default: "", null: false
  end
end
