module Collavre
  class CompressJob < ApplicationJob
    include AiAgentResolvable

    queue_as :default

    def perform(creative_id, topic_id, user_id, extra_prompt = nil)
      creative = Creative.find(creative_id)
      topic = Topic.find(topic_id)
      user = User.find(user_id)

      # Collect all comments in topic (chronological), excluding /compress command
      all_comments = creative.comments
        .where(topic_id: topic_id)
        .order(created_at: :asc)
        .includes(:user)

      # Separate: comments to summarize vs the compress command itself
      compress_pattern = /\A\/compress\b/i
      target_comments = all_comments.reject { |c| c.content.to_s.strip.match?(compress_pattern) }

      return if target_comments.size < 2

      # Build conversation text
      conversation = target_comments.map do |c|
        author = c.user&.name || I18n.t("collavre.comments.anonymous")
        "#{author}: #{c.content}"
      end.join("\n\n")

      # Build AI prompt
      system_prompt = Comments::CompressCommand::SYSTEM_PROMPT.dup
      if extra_prompt.present?
        system_prompt += "\n\nAdditional instruction from the user: #{extra_prompt}"
      end

      # Find an AI agent on this creative, or use default config
      agent = resolve_ai_agent(creative, topic_id)

      client = AiClient.new(
        vendor: agent&.llm_vendor || default_vendor,
        model: agent&.llm_model || default_model,
        system_prompt: system_prompt,
        llm_api_key: agent&.llm_api_key || agent&.creator&.llm_api_key
      )

      summary = String.new
      client.chat([ { role: "user", text: conversation } ]) do |delta|
        summary << delta
      end

      if summary.blank?
        Rails.logger.error("[CompressJob] AI returned empty summary for topic #{topic_id}")
        return
      end

      # Create summary comment
      topic_name = topic.name.presence || "Topic"
      title = I18n.t("collavre.comments.compress_command.summary_title", topic: topic_name)
      summary_content = "**#{title}**\n\n#{summary}"

      # Store comment IDs to delete before creating the new one (all originals including /compress command)
      comment_ids_to_delete = all_comments.pluck(:id)

      # Create the summary comment in the same topic
      summary_comment = creative.comments.create!(
        user: user,
        topic_id: topic_id,
        content: summary_content
      )

      # Delete original comments (excluding the newly created summary)
      creative.comments.where(id: comment_ids_to_delete).destroy_all
    rescue ActiveRecord::RecordNotFound => e
      Rails.logger.error("[CompressJob] Record not found: #{e.message}")
    end
  end
end
