module Collavre
module Creatives
  module Filters
    class ReactionFilter < BaseFilter
      def active?
        params[:reaction_emoji].present?
      end

      def match
        comments = Comment.where(id: CommentReaction.where(emoji: params[:reaction_emoji]).select(:comment_id))
        scope.where(id: comments.select(:creative_id)).pluck(:id)
      end
    end
  end
end
end
