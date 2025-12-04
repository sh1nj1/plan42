module Comments
  class AiResponder
    def initialize(comment:, creative:, helpers: ApplicationController.helpers, logger: Rails.logger)
      @comment = comment
      @creative = creative
      @helpers = helpers
      @logger = logger
    end

    def call
      reply = nil
      # 1. Detect mention at start of comment - support both ID and name
      # Pattern: @username: or @User Name: (supports spaces, Korean, etc.)
      # Stops at colon or end of capitalized words
      match = comment.content.match(/\A@([^:]+?):\s*/) ||
              comment.content.match(/\A@(\S+)\s+/)
      return unless match

      mentioned_name = match[1].strip

      # 2. Find AI User by name (case-insensitive) that is searchable/mentionable
      mentionable_users = User.mentionable_for(creative)

      ai_user = mentionable_users
                  .where("LOWER(name) = ?", mentioned_name.downcase)
                  .find { |u| u.ai_user? }

      return unless ai_user

      # 3. Prepare payload - remove the mention part
      if comment.content.include?(":")
        payload = comment.content.sub(/\A@[^:]+:\s*/i, "").strip
      else
        payload = comment.content.sub(/\A@\S+\s+/i, "").strip
      end
      return if payload.blank?


      reply = creative.comments.create!(content: "...", user: ai_user)

      # 4. Create Agent Run and Enqueue Job
      agent_run = AgentRun.create!(
        creative: creative,
        ai_user: ai_user,
        goal: payload,
        status: "pending"
      )
      agent_run.context = { "comment_id" => reply.id }
      agent_run.save!
      logger.debug("### AgentRun created: #{agent_run.id}, Context: #{agent_run.context}, Reply ID: #{reply.id}")

      AutonomousAgentJob.perform_later(agent_run.id)

    rescue StandardError => e
      logger.error("AI responder failed: #{e.class} #{e.message}")
      begin
        reply&.update!(content: "AI Error: #{e.message}")
      rescue StandardError => update_error
        logger.error("AI responder failed to update reply after error: #{update_error.class} #{update_error.message}")
      end
    end

    private

    attr_reader :comment, :creative, :helpers, :logger

    def build_messages(payload, ai_user)
      AiConversationBuilder.new(creative: creative, ai_user: ai_user, helpers: helpers)
                           .build_messages(payload: payload, user_for_history: comment.user)
    end

    def system_prompt_context(ai_user:, payload:)
      {
        ai_user: {
          id: ai_user.id,
          name: ai_user.name,
          llm_vendor: ai_user.llm_vendor,
          llm_model: ai_user.llm_model
        },
        creative: {
          id: creative.id,
          description: creative.effective_description(nil, false),
          progress: creative.progress,
          owner_name: creative.user&.name
        },
        comment: {
          id: comment.id,
          content: comment.content,
          user_name: comment.user&.name
        },
        payload: payload
      }
    end
  end
end
