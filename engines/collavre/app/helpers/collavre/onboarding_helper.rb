# frozen_string_literal: true

module Collavre
  module OnboardingHelper
    def self.session_for(creative, user:)
      return unless user && creative&.user_id == user.id && !user.onboarding_completed_at?

      Onboarding::Session.for_creative(creative)
    end
  end
end
