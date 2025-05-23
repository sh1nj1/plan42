class AddSequenceToCreatives < ActiveRecord::Migration[8.0]
  def change
    add_column :creatives, :sequence, :integer, default: 0, null: false
  end
end
