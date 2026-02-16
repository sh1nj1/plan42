# frozen_string_literal: true

module Collavre
  module AiAgent
    # Builds the message array for AI agent conversations.
    #
    # Extracts creative context, chat history, and the trigger comment
    # into the format expected by AiClient.
    class MessageBuilder
      def initialize(agent:, context:, original_comment: nil)
        @agent = agent
        @context = context
        @original_comment = original_comment
      end

      def build
        messages = []

        append_creative_context(messages)
        append_chat_history(messages)
        append_trigger_message(messages)

        messages
      end

      private

      def append_creative_context(messages)
        creative_id = @context.dig("creative", "id")
        return unless creative_id

        creative = Creative.find_by(id: creative_id)
        return unless creative

        children_level = @agent.creative_children_level
        max_depth = 1 + children_level
        markdown = ApplicationController.helpers.render_creative_tree_markdown(
          [ creative ], 1, true, max_depth: max_depth
        )
        messages << { role: "user", parts: [ { text: "Creative (id: #{creative.id}):\n#{markdown}" } ] }
      end

      def append_chat_history(messages)
        creative_id = @context.dig("creative", "id")
        return unless creative_id

        trigger_comment_id = @context.dig("comment", "id")
        trigger_comment = Comment.find_by(id: trigger_comment_id)
        topic_id = trigger_comment&.topic_id

        history_limit = @agent.chat_history_limit
        history_size_limit = @agent.chat_history_size_limit
        history_chars = 0

        Comment.where(creative_id: creative_id, private: false)
               .where(topic_id: topic_id)
               .includes(:user)
               .order(created_at: :desc)
               .limit(history_limit)
               .reverse
               .each do |c|
          next if c.id == @context.dig("comment", "id")

          role = (c.user_id == @agent.id) ? "model" : "user"
          content = c.content.to_s

          if role == "user"
            content = MentionParser.strip_self_mention(content, @agent.name)
            speaker = c.user&.name || "unknown"
            content = "[#{speaker}]: #{content}"
          end

          history_chars += content.length
          break if history_chars > history_size_limit

          messages << { role: role, parts: [ { text: content } ] }
        end
      end

      def append_trigger_message(messages)
        payload_text = @context.dig("comment", "content") || @context.to_json

        if review_eligible?
          quoted_body = @original_comment.quoted_comment&.content
          review_context = I18n.t("collavre.ai_agent.review.context")
          review_parts = [ review_context ]
          review_parts << "---\nOriginal message:\n#{quoted_body}\n---" if quoted_body.present?
          payload_text = "#{review_parts.join("\n\n")}\n\n#{payload_text}"
        end

        sender_name = @context.dig("sender", "name")
        if sender_name
          payload_text = MentionParser.strip_self_mention(payload_text, @agent.name)
          payload_text = "[#{sender_name}]: #{payload_text}"
        end

        trigger_parts = [ { text: payload_text } ]

        if @original_comment&.images&.attached?
          @original_comment.images.each do |image|
            trigger_parts << { image: image.blob }
          end
        end

        messages << { role: "user", parts: trigger_parts }
      end

      def review_eligible?
        ReviewHandler.eligible?(@original_comment, @agent)
      end
    end
  end
end
