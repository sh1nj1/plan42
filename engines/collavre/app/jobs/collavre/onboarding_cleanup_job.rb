# frozen_string_literal: true

module Collavre
  # Keeps the final onboarding conversation available until its agent turn has
  # reached a terminal state. The session id prevents a later reset from being
  # affected by this delayed cleanup.
  class OnboardingCleanupJob < ApplicationJob
    queue_as :default

    RETRY_DELAY = 5.seconds

    def perform(user_id, session_id)
      user = User.find_by(id: user_id)
      return unless user

      cleaned = Onboarding::CompletionService.new(user: user).clean_up_when_agent_turn_settles(session_id)
      self.class.set(wait: RETRY_DELAY).perform_later(user_id, session_id) unless cleaned
    end
  end
end
