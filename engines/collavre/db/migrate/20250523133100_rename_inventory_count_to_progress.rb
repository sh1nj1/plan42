class RenameInventoryCountToProgress < ActiveRecord::Migration[7.0]
  def up
    rename_column :creatives, :inventory_count, :progress
    change_column :creatives, :progress, :float, using: 'progress::float', default: 0.0
    change_column_default :creatives, :progress, 0.0
  end

  def down
    change_column_default :creatives, :progress, nil
    change_column :creatives, :progress, :integer, using: 'progress::integer'
    rename_column :creatives, :progress, :inventory_count
  end
end
