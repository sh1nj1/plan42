class CreateLabels < ActiveRecord::Migration[8.0]
  def change
    create_table :labels do |t|
      t.string :type
      t.string :name
      t.string :value
      t.date :target_date

      t.timestamps
    end
  end
end
