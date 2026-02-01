class MakeGoogleEventIdNullable < ActiveRecord::Migration[8.0]
  def change
    change_column_null :calendar_events, :google_event_id, true
  end
end
