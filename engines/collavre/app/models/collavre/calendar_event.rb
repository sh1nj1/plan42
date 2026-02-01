module Collavre
  class CalendarEvent < ApplicationRecord
    self.table_name = "calendar_events"

    belongs_to :user, class_name: Collavre.configuration.user_class_name
    belongs_to :creative, class_name: "Collavre::Creative", optional: true

    validates :start_time, :end_time, presence: true

    after_commit :delete_google_event, on: :destroy

    def synced_to_google?
      google_event_id.present?
    end

    private

    def delete_google_event
      return unless google_event_id.present?

      GoogleCalendarService.new(user: user).delete_event(google_event_id)
    rescue StandardError => e
      Rails.logger.error("Failed to delete Google event #{google_event_id}: #{e.message}")
    end
  end
end
