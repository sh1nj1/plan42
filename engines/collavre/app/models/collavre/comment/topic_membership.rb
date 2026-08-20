# frozen_string_literal: true

module Collavre
  class Comment
    module TopicMembership
      extend ActiveSupport::Concern

      included do
        before_validation :assign_main_topic, on: :create
        before_validation :stamp_topic_assignment
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
    end
  end
end
