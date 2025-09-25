module Comments
  class GeminiResponder
    def initialize(comment:, creative:, helpers: ApplicationController.helpers, logger: Rails.logger)
      @comment = comment
      @creative = creative
      @helpers = helpers
      @logger = logger
    end

    def call
      payload = sanitized_content
      return if payload.blank?

      messages = build_messages(payload)
      reply = creative.comments.create!(content: "...", user: comment.user)

      logger.debug("### Gemini chat: #{messages}")
      accumulator = "gemini: "

      GeminiChatClient.new.chat(messages) do |delta|
        next if delta.blank?

        accumulator += delta
        begin
          reply.update!(content: accumulator)
          logger.debug("### Gemini chat: #{accumulator}")
        rescue StandardError => e
          logger.error("Gemini reply update failed: #{e.class} #{e.message}")
        end
      end
    rescue StandardError => e
      logger.error("Gemini responder failed: #{e.class} #{e.message}")
    end

    private

    attr_reader :comment, :creative, :helpers, :logger

    def sanitized_content
      comment.content.sub(/\A@gemini\s*/i, "").strip
    end

    def build_messages(payload)
      messages = []
      markdown = helpers.render_creative_tree_markdown([ creative ], 1, true)
      messages << { role: "user", parts: [ { text: "Creative:\n#{markdown}" } ] }

      creative.comments.where("comments.private = ? OR comments.user_id = ?", false, comment.user_id)
              .order(:created_at).each do |c|
        role = c.user_id ? "user" : "model"
        text = c.content.sub(/\A@gemini\s*/i, "")
        messages << { role: role, parts: [ { text: text } ] }
      end

      messages << { role: "user", parts: [ { text: payload } ] }
      messages
    end
  end
end
