module Collavre
module Creatives
  module Filters
    class TagFilter < BaseFilter
      def active?
        params[:tags].present?
      end

      def match
        tag_ids = Array(params[:tags]).map(&:to_s)
        scope.joins(:tags).where(tags: { label_id: tag_ids }).pluck(:id)
      end
    end
  end
end
end
