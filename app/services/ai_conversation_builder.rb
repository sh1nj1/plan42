class AiConversationBuilder
  def initialize(creative:, ai_user:, helpers: ApplicationController.helpers)
    @creative = creative
    @ai_user = ai_user
    @helpers = helpers
  end

  def build_messages(payload: nil, include_history: true, user_for_history: nil)
    messages = []
    markdown = @helpers.render_creative_tree_markdown([ @creative ], 1, true)
    messages << { role: "user", parts: [ { text: "Creative:\n#{markdown}" } ] }

    if include_history
      # Fetch context history
      scope = @creative.comments.order(:created_at)

      if user_for_history
        scope = scope.where("comments.private = ? OR comments.user_id = ?", false, user_for_history.id)
      else
        scope = scope.where(private: false)
      end

      scope.each do |c|
        role = (c.user_id == @ai_user.id) ? "model" : "user"

        text = c.content
        if role == "user"
          text = clean_mention(text, @ai_user.name)
        end

        messages << { role: role, parts: [ { text: text } ] }
      end
    end

    if payload.present?
      messages << { role: "user", parts: [ { text: payload } ] }
    end

    messages
  end

  private

  def clean_mention(text, bot_name)
    if text.match?(/\A@#{Regexp.escape(bot_name)}:/i)
      text.sub(/\A@#{Regexp.escape(bot_name)}:\s*/i, "")
    elsif text.match?(/\A@#{Regexp.escape(bot_name)}\s+/i)
      text.sub(/\A@#{Regexp.escape(bot_name)}\s+/i, "")
    else
      text
    end
  end
end
