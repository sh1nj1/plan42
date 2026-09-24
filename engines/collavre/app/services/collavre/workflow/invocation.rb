# frozen_string_literal: true

module Collavre
  module Workflow
    # Persist the visible instruction and its dispatch anchor in the admission
    # transaction. Outbox retries reuse this anchor and never repost the message.
    class Invocation
      def initialize(execution)
        @execution = execution
      end

      def self.usable_topic?(topic, creative_id)
        topic && topic.creative_id == creative_id && !topic.archived? && !topic.history? &&
          topic.session_id.blank? && !(topic.creative.inbox? && topic.name == Creative::SYSTEM_TOPIC_NAME)
      end

      def topic
        @topic ||= begin
          name = @execution.rule_snapshot["topic_name"]&.strip.presence || Creative::MAIN_TOPIC_NAME
          return if name == Creative::HISTORY_TOPIC_NAME
          creative.topics.find_or_create_by!(name: name) { |row| row.user = creative.user }
        rescue ActiveRecord::RecordInvalid => error
          creative.topics.find_by(name: name) || raise(error)
        end
      end

      def scheduling_context
        @execution.context.merge("topic" => { "id" => topic.id })
      end

      def persist!
        topic.with_lock do
          next unless self.class.usable_topic?(topic, creative.id) && creative.reload.archived_at.nil?
          comment = creative.comments.create!(topic: topic, user_id: @execution.context.dig("comment", "user_id"),
            content: @execution.rule_snapshot.fetch("instruction"),
            skip_default_user: true, skip_dispatch: true)
          payload = comment.dispatch_payload.deep_stringify_keys
          payload["chat"] = { "content" => comment.content, "mentioned_users" => [] }
          payload["sender"] = SystemEvents::ContextBuilder.sender_context_for(comment.user)
          @execution.update!(context: @execution.context.merge("invocation" => payload))
          comment
        end
      end
      private

      def creative
        @creative ||= Creative.find(@execution.chain.creative_id)
      end
    end
  end
end
