class ChangeTagToLabelReference < ActiveRecord::Migration[7.0]
  def change
    remove_reference :tags, :taggable, polymorphic: true, index: true
    add_reference :tags, :label, foreign_key: true
  end
end
