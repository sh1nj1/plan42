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
            items.each(&:capture_broadcast_state)
            preserve_non_session_children(item_ids)
            CreativeShare.where(creative_id: item_ids).destroy_all if item_ids.any?
            items.sort_by { |creative| -creative.ancestors.count }.each do |creative|
              creative.destroy! if creative.persisted?
            end
            if mark_completed
              Comment.find_by(notification_key: Seeder.welcome_notification_key(user))&.destroy!
              user.update!(onboarding_completed_at: Time.current)
            end
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

      def preserve_non_session_children(item_ids)
        Creative.where(parent_id: item_ids).where.not(id: item_ids).find_each do |creative|
          destination = creative.parent
          destination = destination.parent while destination && item_ids.include?(destination.id)
          creative.update!(parent: destination)
        end
      end
    end
  end
end
