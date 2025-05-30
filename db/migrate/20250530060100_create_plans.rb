class CreatePlans < ActiveRecord::Migration[7.0]
  def change
    create_table :plans do |t|
      t.date :target_date, null: false
      t.string :name
      t.timestamps
    end
  end
end
