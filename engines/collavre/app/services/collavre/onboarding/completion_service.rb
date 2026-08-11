# frozen_string_literal: true

module Collavre
  module Onboarding
    class CompletionService
      def initialize(user:)
        @user = user
      end

      def call
        session = Session.for_user(user)
        session_id = session&.session_id
        # The session id, not current tree position, is the ownership boundary.
        # This keeps moved practice items from becoming permanent clutter. If
        # the root was deleted, every remaining tagged item is orphaned and
        # must be removed before onboarding can be reset or completed.
        owned = user.creatives.select do |creative|
          creative_session_id = creative.data&.dig("onboarding", "session_id")
          creative_session_id.present? && (session_id.nil? || creative_session_id == session_id)
        end
        owned.sort_by { |creative| -creative.ancestors.count }.each(&:destroy!)
        user.update!(onboarding_completed_at: Time.current)
      end

      private

      attr_reader :user
    end
  end
end
