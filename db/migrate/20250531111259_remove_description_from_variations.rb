class RemoveDescriptionFromVariations < ActiveRecord::Migration[8.0]
  def change
    remove_column :variations, :description, :string
  end
end
