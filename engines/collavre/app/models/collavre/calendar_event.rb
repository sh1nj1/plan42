module Collavre
  class CalendarEvent < ApplicationRecord
    self.table_name = "calendar_events"

    belongs_to :user, class_name: Collavre.configuration.user_class_name
    belongs_to :creative, class_name: "Collavre::Creative", optional: true

    validates :start_time, :end_time, presence: true

    after_commit :delete_google_event, on: :destroy

    private

    def delete_google_event
      return unless google_event_id.present?

      DeleteGoogleEventJob.perform_later(user_id, google_event_id)
    end
  end
end
