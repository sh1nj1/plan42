module Creatives
  module Filters
    class CommentFilter < BaseFilter
      def active?
        params[:has_comments].present? || params[:comment].present?
      end

      def match
        has_comments = params[:has_comments] == "true" || params[:comment] == "true"

        if has_comments
          scope.joins(:comments).distinct.pluck(:id)
        else
          scope.left_joins(:comments).where(comments: { id: nil }).pluck(:id)
        end
      end
    end
  end
end
