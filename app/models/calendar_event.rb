class CalendarEvent < ApplicationRecord
  belongs_to :user

  validates :google_event_id, :start_time, :end_time, presence: true
end
