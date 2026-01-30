class AddStartDateToLabels < ActiveRecord::Migration[8.0]
  def change
    add_column :labels, :start_date, :date
  end
end
