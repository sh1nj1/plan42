# frozen_string_literal: true

module Collavre
  module Workflow
    # A System notice is never a dispatch. Avoid the ordinary source-topic lock
    # while retaining atomic notice/seal persistence under the chain lock.
    class InboxNotice
      def self.persist!(inbox:, owner:, key:, content:)
        topic = inbox.system_topic(fallback_user: owner)
        inbox.reload
        topic.reload
        unless inbox.inbox? && inbox.origin_id.nil? && inbox.user_id == owner.id &&
            inbox.archived_at.nil? && topic.creative_id == inbox.id && topic.name == Creative::SYSTEM_TOPIC_NAME && !topic.archived?
          raise ActiveRecord::RecordInvalid, inbox
        end
        existing = Comment.find_by(notification_key: key)
        return existing if existing
        insert!(inbox, topic, key, content)
      end

      def self.insert!(inbox, topic, key, content)
        now = Time.current
        result = Comment.insert_all!([ { creative_id: inbox.id, topic_id: topic.id,
          notification_key: key, content: content, user_id: nil, quoted_comment_id: nil,
          action: nil, approver_id: nil, task_id: nil, private: false,
          topic_assigned_at: now, created_at: now, updated_at: now } ], returning: %w[id])
        Creative.increment_counter(:comments_count, inbox.id)
        comment = Comment.find(result.rows.first.first)
        ActiveRecord.after_all_transactions_commit { broadcast(comment) }
        comment
      end

      def self.broadcast(comment)
        comment.send(:broadcast_create)
        comment.send(:broadcast_badges)
      rescue StandardError => error
        Rails.logger.warn("[Workflow] inbox_comment_id=#{comment.id} broadcast_error=#{error.class.name}")
      end

      private_class_method :insert!, :broadcast
    end
  end
end
