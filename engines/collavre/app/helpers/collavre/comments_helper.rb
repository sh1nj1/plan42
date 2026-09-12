module Collavre
  module CommentsHelper
    def formatted_comment_action(comment)
      JSON.pretty_generate(JSON.parse(comment.action))
    rescue JSON::ParserError, TypeError
      comment.action.to_s
    end

    def comment_action_markdown(comment)
      parsed = JSON.parse(comment.action)
      parsed["markdown"] if parsed.is_a?(Hash) && parsed["markdown"].present?
    rescue JSON::ParserError, TypeError
      nil
    end
  end
end
