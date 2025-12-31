class DropSubscribers < ActiveRecord::Migration[8.1]
  def change
    drop_table :subscribers do |t|
      t.belongs_to :creative, null: false, foreign_key: true
      t.string :email
      t.timestamps
    end
  end
end
