# frozen_string_literal: true

module Collavre
  class Comment
    module TopicMembership
      extend ActiveSupport::Concern

      included do
        before_validation :assign_main_topic, on: :create
        before_validation :stamp_topic_assignment
        before_create :lock_matching_topic
      end

      private

      def assign_main_topic
        return if topic_id.present?
        return unless creative

        fallback = user || Collavre.current_user || creative.user
        self.topic = creative.main_topic(fallback_user: fallback)
      end

      # Paging snapshots topic membership separately from comment ids. Content
      # edits leave this timestamp alone; topic changes advance it.
      def stamp_topic_assignment
        return unless will_save_change_to_topic_id? || topic_assigned_at.nil?

        self.topic_assigned_at = Time.current
      end

      # Notifications retain their resolved System object if DELETE wins before
      # insertion. Retry only this reserved destination; ordinary stale topics
      # must still fail. The lock is held by the enclosing comment transaction.
      def lock_destination_topic
        return Topic.where(id: topic_id).lock.first unless system_notification_destination?

        3.times do |attempt|
          locked = Topic.where(id: topic_id).lock("FOR KEY SHARE").first
          return locked if locked

          self.topic = creative.system_topic if attempt < 2
        end
        nil
      end

      def system_notification_destination?
        user_id.nil? && creative&.inbox? && topic&.creative_id == creative_id &&
          topic.name == Creative::SYSTEM_TOPIC_NAME
      end

      def lock_matching_topic
        locked_topic = lock_destination_topic
        return if locked_topic&.creative_id == creative_id

        errors.add(:topic, I18n.t("collavre.comments.invalid_topic"))
        throw :abort
      end
    end
  end
end
