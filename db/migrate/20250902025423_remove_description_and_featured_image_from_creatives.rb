class RemoveDescriptionAndFeaturedImageFromCreatives < ActiveRecord::Migration[8.0]
  def change
    remove_column :creatives, :description, :text
    remove_column :creatives, :featured_image, :string
  end
end