module Creatives
  module Filters
    class CommentFilter < BaseFilter
      def active?
        params[:comment] == "true"
      end

      def match
        scope.joins(:comments).distinct.pluck(:id)
      end
    end
  end
end
