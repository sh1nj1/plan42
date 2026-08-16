# frozen_string_literal: true

module Collavre
  # Keeps the final onboarding conversation available until its agent turn has
  # reached a terminal state. The session id prevents a later reset from being
  # affected by this delayed cleanup.
  class OnboardingCleanupJob < ApplicationJob
    queue_as :default

    # A task can intentionally stay pending approval indefinitely. Keep the
    # final conversation available for a reasonable window without creating an
    # unbounded stream of retries when no terminal transition will occur.
    RETRY_DELAYS = [ 5.seconds, 30.seconds, 5.minutes, 30.minutes, 2.hours, 6.hours ].freeze

    def perform(user_id, session_id, attempt = 0)
      user = User.find_by(id: user_id)
      return unless user

      cleaned = Onboarding::CompletionService.new(user: user).clean_up_when_agent_turn_settles(session_id)
      retry_delay = RETRY_DELAYS[attempt]
      self.class.set(wait: retry_delay).perform_later(user_id, session_id, attempt + 1) if !cleaned && retry_delay
    end
  end
end
