# frozen_string_literal: true

module Collavre
  # Deletes a Google Calendar event out-of-band so the deleting request is
  # not blocked on a synchronous HTTP call to Google.
  class DeleteGoogleEventJob < ApplicationJob
    queue_as :default

    discard_on ActiveJob::DeserializationError
    discard_on ActiveRecord::RecordNotFound

    def perform(user_id, google_event_id)
      return if google_event_id.blank?

      user = Collavre.configuration.user_class_name.constantize.find_by(id: user_id)
      return unless user

      GoogleCalendarService.new(user: user).delete_event(google_event_id)
    rescue StandardError => e
      Rails.logger.error("Failed to delete Google event #{google_event_id}: #{e.message}")
    end
  end
end
