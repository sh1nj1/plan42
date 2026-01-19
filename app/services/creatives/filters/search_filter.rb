module Creatives
  module Filters
    class SearchFilter < BaseFilter
      def active?
        params[:search].present?
      end

      def match
        query = "%#{sanitize_like(params[:search])}%"

        # Search in description OR comments.content
        scope
          .left_joins(:comments)
          .where("creatives.description LIKE :q OR comments.content LIKE :q", q: query)
          .distinct
          .pluck(:id)
      end

      private

      def sanitize_like(str)
        str.to_s.gsub(/[%_]/) { |m| "\\#{m}" }
      end
    end
  end
end
