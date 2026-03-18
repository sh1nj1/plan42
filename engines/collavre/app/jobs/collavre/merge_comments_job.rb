module Collavre
  class MergeCommentsJob < ApplicationJob
    include AiAgentResolvable

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
        .includes(:user)
        .to_a

      return if comments.size < 2

      target_comment = comments.first
      topic_id = target_comment.topic_id

      # Build conversation text
      conversation = comments.map do |c|
        author = c.user&.name || I18n.t("collavre.comments.anonymous")
        "#{author}: #{c.content}"
      end.join("\n\n")

      # Resolve AI agent (same as /compress)
      agent = resolve_ai_agent(creative, topic_id)

      client = AiClient.new(
        vendor: agent&.llm_vendor || default_vendor,
        model: agent&.llm_model || default_model,
        system_prompt: SYSTEM_PROMPT,
        llm_api_key: agent&.llm_api_key || agent&.creator&.llm_api_key
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

      # Update the first comment and delete the rest atomically
      remaining_ids = comments[1..].map(&:id)
      ActiveRecord::Base.transaction do
        target_comment.update!(content: merged_content)
        creative.comments.where(id: remaining_ids).destroy_all
      end
    rescue ActiveRecord::RecordNotFound => e
      Rails.logger.error("[MergeCommentsJob] Record not found: #{e.message}")
    end
  end
end
