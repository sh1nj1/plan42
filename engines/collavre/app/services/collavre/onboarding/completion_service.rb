# frozen_string_literal: true

module Collavre
  module Onboarding
    class CompletionService
      def self.call(user:, session_id:, mark_completed: true)
        new(user: user, session_id: session_id, mark_completed: mark_completed).call
      end

      def initialize(user:, session_id:, mark_completed: true)
        @user = user
        @session_id = session_id
        @mark_completed = mark_completed
      end

      def call
        return false if user.nil? || session_id.blank?

        User.transaction do
          user.with_lock do
            items = session_items
            item_ids = items.map(&:id)
            CreativeShare.where(creative_id: item_ids).destroy_all if item_ids.any?
            items.sort_by { |creative| -creative.ancestors.count }.each do |creative|
              creative.destroy! if creative.persisted?
            end
            user.update!(onboarding_completed_at: Time.current) if mark_completed
          end
        end
        true
      end

      private

      attr_reader :user, :session_id, :mark_completed

      def session_items
        Creative.where(user: user).select do |creative|
          creative.onboarding_metadata&.dig("session_id") == session_id
        end
      end
    end
  end
end
