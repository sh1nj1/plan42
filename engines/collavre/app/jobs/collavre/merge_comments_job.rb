module Collavre
  class MergeCommentsJob < ApplicationJob
    include AiAgentResolvable
    include CommentSerializable

    queue_as :default

    SYSTEM_PROMPT = <<~PROMPT.freeze
      You are merging multiple chat messages into a single coherent message.
      Synthesize the content from all messages, preserving all important information,
      decisions, action items, and context.
      Do not add commentary about the merge process itself.
      Respond in the same language as the original messages.
      Use markdown formatting for readability.
    PROMPT

    def perform(creative_id, comment_ids, user_id) # rubocop:disable Lint/UnusedMethodArgument -- user_id reserved for future audit/notification use
      creative = Creative.find(creative_id)

      # Fetch comments in chronological order
      comments = creative.comments
        .where(id: comment_ids)
        .order(created_at: :asc)
        .includes(:user, images_attachments: :blob)
        .to_a

      return unless mergeable_selection?(comments)

      target_comment = comments.first
      topic_id = target_comment.topic_id

      # Build conversation text
      conversation = comments.map do |c|
        author = c.user&.name || I18n.t("collavre.comments.anonymous")
        "#{author}: #{c.content}"
      end.join("\n\n")

      # Resolve AI agent (same as /compress — agent is required)
      agent = resolve_ai_agent(creative, topic_id)

      unless agent
        Rails.logger.error("[MergeCommentsJob] No AI agent found for creative #{creative_id}")
        return
      end

      client = AiClient.new(
        vendor: agent.llm_vendor,
        model: agent.llm_model,
        system_prompt: SYSTEM_PROMPT,
        llm_api_key: agent.llm_api_key || agent.creator&.llm_api_key,
        gateway_url: agent.gateway_url.presence || agent.creator&.gateway_url,
        context: {
          creative: creative,
          user: agent,
          topic_id: topic_id
        }
      )

      merged_content = String.new
      result = client.chat([ { role: "user", text: conversation } ]) do |delta|
        merged_content << delta
      end

      # AiClient returns nil on error (but still yields error text as delta).
      # Check both: return value must be truthy AND content must be non-blank.
      if result.nil? || merged_content.blank?
        Rails.logger.error("[MergeCommentsJob] AI failed for comments #{comment_ids}")
        return
      end

      Comments::TopicMutation.call(topic_id, creative_id) do
        current_comments = lock_current_comments(comments, creative_id, topic_id)
        persist_merge(current_comments, merged_content, user_id) if current_comments
      end
    rescue ActiveRecord::RecordNotFound => e
      Rails.logger.error("[MergeCommentsJob] Record not found: #{e.message}")
    end

    private

    def mergeable_selection?(comments)
      comments.size >= 2 && comments.map(&:topic_id).uniq.size == 1
    end

    def lock_current_comments(comments, creative_id, topic_id)
      current_comments = Comment.where(id: comments.map(&:id)).order(created_at: :asc).lock.to_a
      return unless current_comments.size == comments.size
      return unless current_comments.all? { |comment| comment.creative_id == creative_id && comment.topic_id == topic_id }

      current_comments
    end

    def persist_merge(comments, merged_content, user_id)
      target_comment = comments.first
      creative = target_comment.creative
      CommentSnapshot.create!(
        creative: creative,
        topic_id: target_comment.topic_id,
        user_id: user_id,
        operation: "merge",
        comments_data: serialize_comments(comments),
        result_comment: target_comment
      )
      target_comment.update!(content: merged_content)
      creative.comments.where(id: comments[1..].map(&:id)).destroy_all
    end
  end
end
