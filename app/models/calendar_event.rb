class CalendarEvent < ApplicationRecord
  belongs_to :user
  belongs_to :creative, optional: true

  validates :google_event_id, :start_time, :end_time, presence: true
end
