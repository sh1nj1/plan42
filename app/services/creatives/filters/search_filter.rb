module Creatives
  module Filters
    class SearchFilter < BaseFilter
      def active?
        params[:search].present?
      end

      def match
        search_term = "%#{params[:search]}%"

        # description 검색 (LIKE is case-insensitive in SQLite by default)
        desc_matches = scope.where("description LIKE ?", search_term).pluck(:id)

        # comments 검색
        comment_matches = scope
          .joins(:comments)
          .where("comments.content LIKE ?", search_term)
          .distinct
          .pluck(:id)

        (desc_matches + comment_matches).uniq
      end
    end
  end
end
