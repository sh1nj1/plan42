class DropPlansAndVariations < ActiveRecord::Migration[6.1]
  def change
    drop_table :plans, if_exists: true
    drop_table :variations, if_exists: true
  end
end
