# frozen_string_literal: true

module Collavre
  module HasInboxCreative
    extend ActiveSupport::Concern

    included do
      after_create_commit :create_inbox_creative, unless: :ai_user?
    end

    # Returns the user's inbox creative, creating one if it doesn't exist.
    def inbox_creative
      Collavre::Creative.inbox_for(self)
    end

    private

    def create_inbox_creative
      inbox = Collavre::Creative.inbox_for(self)
      onboard_kollavy(inbox)
    rescue StandardError => e
      Rails.logger.error("[HasInboxCreative] Failed to create inbox for user #{id}: #{e.message}")
    end

    # A new user gets the Kollavy guide right away instead of at the next seed.
    def onboard_kollavy(inbox)
      Collavre::Kollavy.onboard_inbox(inbox)
    rescue StandardError => e
      Rails.logger.error("[HasInboxCreative] Failed to onboard Kollavy for user #{id}: #{e.message}")
    end
  end
end
