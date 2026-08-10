# frozen_string_literal: true

module Collavre
  module Onboarding
    class CompletionService
      def initialize(user:)
        @user = user
      end

      def call
        session = Session.for_user(user)
        return unless session

        session_id = session.session_id
        # The session id, not current tree position, is the ownership boundary.
        # This keeps moved practice items from becoming permanent clutter.
        owned = user.creatives.select { |creative| creative.data&.dig("onboarding", "session_id") == session_id }
        owned.sort_by { |creative| -creative.ancestors.count }.each(&:destroy!)
        user.update!(onboarding_completed_at: Time.current)
      end

      private

      attr_reader :user
    end
  end
end
