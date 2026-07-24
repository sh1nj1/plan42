# frozen_string_literal: true

module Collavre
  module HasProfileCreative
    extend ActiveSupport::Concern

    included do
      after_create_commit :create_profile_creative
    end

    # Returns the user's profile creative, creating one if it doesn't exist.
    # Use only from write paths (e.g. sync_profile_system_prompt!) — never from
    # a hot read path, since creating a profile creative also creates a Topic.
    def profile_creative
      Collavre::Creative.profile_for(self)
    end

    # Read-only lookup: the existing profile creative or nil, never creating one.
    # Read paths (effective_system_prompt) must use this so a hot-path read never
    # writes, and so rendering never fails when the in-memory user is invalid
    # (e.g. re-rendering the AI form after a failed save leaves name blank).
    def profile_creative_if_present
      return nil unless persisted?

      # A partial unique index enforces one profile per user, so at most one row
      # matches; order(:id) is defensive (matches profile_for's selection) for
      # any pre-index legacy duplicate, keeping reads and writes on the same row.
      Collavre::Creative.profiles.where(user: self).order(:id).first
    end

    private

    def create_profile_creative
      Collavre::Creative.profile_for(self)
    rescue StandardError => e
      Rails.logger.error("[HasProfileCreative] Failed to create profile for user #{id}: #{e.message}")
    end
  end
end
