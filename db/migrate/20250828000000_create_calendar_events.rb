class CreateCalendarEvents < ActiveRecord::Migration[8.0]
  def change
    create_table :calendar_events do |t|
      t.references :user, null: false, foreign_key: true
      t.string :google_event_id, null: false
      t.string :summary
      t.datetime :start_time, null: false
      t.datetime :end_time, null: false
      t.string :html_link

      t.timestamps
    end

    add_index :calendar_events, :google_event_id, unique: true
  end
end
