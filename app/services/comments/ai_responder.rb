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

      messages = build_messages(payload, ai_user)
      reply = creative.comments.create!(content: "...", user: ai_user)

      logger.debug("### AI Chat (#{ai_user.name}): #{messages}")
      accumulator = ""  # No prefix - just the response

      # 4. Call AI Client
      client = AiClient.new(
        vendor: ai_user.llm_vendor,
        model: ai_user.llm_model,
        system_prompt: ai_user.system_prompt,
        llm_api_key: ai_user.llm_api_key
      )

      client.chat(messages, tools: ai_user.tools || []) do |delta|
        next if delta.blank?

        accumulator += delta
        begin
          reply.update!(content: accumulator)
          logger.debug("### AI Chat (#{ai_user.name}): #{accumulator}")
        rescue StandardError => e
          logger.error("AI reply update failed: #{e.class} #{e.message}")
        end
      end

      # If no response was received, update the reply with an error placeholder
      if accumulator.blank?
        reply.update!(content: "Error: No response from AI model.")
        logger.error("AI responder: No response received for comment ##{comment.id}")
      end
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
      messages = []
      markdown = helpers.render_creative_tree_markdown([ creative ], 1, true)
      messages << { role: "user", parts: [ { text: "Creative:\n#{markdown}" } ] }

      # Fetch context history
      # We include comments that are public or owned by the user who triggered the bot
      # We also need to handle the roles correctly.
      # If the comment author is the AI user itself, role is 'model'.
      # If it's another user, role is 'user'.

      creative.comments.where("comments.private = ? OR comments.user_id = ?", false, comment.user_id)
              .order(:created_at).each do |c|
        role = (c.user_id == ai_user.id) ? "model" : "user"

        # Clean up the content if it was a mention to THIS bot
        # Strip the mention if it matches the current bot's name to avoid confusion
        text = c.content
        if role == "user"
          # Remove @BotName: or @BotName format
          if text.match?(/\A@#{Regexp.escape(ai_user.name)}:/i)
            text = text.sub(/\A@#{Regexp.escape(ai_user.name)}:\s*/i, "")
          elsif text.match?(/\A@#{Regexp.escape(ai_user.name)}\s+/i)
            text = text.sub(/\A@#{Regexp.escape(ai_user.name)}\s+/i, "")
          end
        end

        messages << { role: role, parts: [ { text: text } ] }
      end

      messages << { role: "user", parts: [ { text: payload } ] }
      messages
    end
  end
end
