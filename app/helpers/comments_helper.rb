module CommentsHelper
  def formatted_comment_action(comment)
    JSON.pretty_generate(JSON.parse(comment.action))
  rescue JSON::ParserError, TypeError
    comment.action.to_s
  end
end
