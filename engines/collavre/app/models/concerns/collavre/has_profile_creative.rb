# frozen_string_literal: true

module Collavre
  module HasProfileCreative
    extend ActiveSupport::Concern

    included do
      after_create_commit :create_profile_creative
    end

    # Returns the user's profile creative, creating one if it doesn't exist.
    def profile_creative
      Collavre::Creative.profile_for(self)
    end

    private

    def create_profile_creative
      Collavre::Creative.profile_for(self)
    rescue StandardError => e
      Rails.logger.error("[HasProfileCreative] Failed to create profile for user #{id}: #{e.message}")
    end
  end
end
