module Collavre
  class CompressJob < ApplicationJob
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
      result = client.chat([ { role: "user", text: conversation } ]) do |delta|
        summary << delta
      end

      # AI call failed (returned nil) — do NOT delete original comments
      if result.nil? || summary.blank?
        Rails.logger.error("[CompressJob] AI call failed for topic #{topic_id}: #{summary.presence || 'empty response'}")
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

    private

    # Resolve AI agent using orchestration rules:
    # 1. Topic's primary agent (from OrchestratorPolicy)
    # 2. Fallback: any AI agent with feedback permission on the creative
    def resolve_ai_agent(creative, topic_id)
      # Step 1: Check topic's primary agent via OrchestratorPolicy
      if topic_id.present?
        context = build_policy_context(creative, topic_id)
        resolver = Orchestration::PolicyResolver.new(context)
        primary_id = resolver.primary_agent_id

        if primary_id.present?
          agent = User.find_by(id: primary_id)
          return agent if agent&.ai_user?
        end
      end

      # Step 2: Fallback - find any AI agent with access
      creative.effective_origin.all_shared_users(:feedback)
        .map(&:user)
        .find(&:ai_user?)
    end

    def build_policy_context(creative, topic_id)
      context = {}
      context["creative"] = { "id" => creative.id }
      context["topic"] = { "id" => topic_id } if topic_id.present?
      context
    end

    def default_vendor
      "google"
    end

    def default_model
      "gemini-3-flash-preview"
    end
  end
end
