class CalendarEvent < ApplicationRecord
  belongs_to :user
  belongs_to :creative, optional: true

  validates :google_event_id, :start_time, :end_time, presence: true

  after_commit :delete_google_event, on: :destroy

  private

  def delete_google_event
    GoogleCalendarService.new(user: user).delete_event(google_event_id)
  rescue StandardError => e
    Rails.logger.error("Failed to delete Google event #{google_event_id}: #{e.message}")
  end
end
