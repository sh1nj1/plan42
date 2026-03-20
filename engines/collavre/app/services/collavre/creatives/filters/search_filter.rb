module Collavre
module Creatives
  module Filters
    class SearchFilter < BaseFilter
      MAX_SEARCH_WORDS = 5

      def active?
        params[:search].present?
      end

      def match
        words = params[:search].to_s.strip.split(/\s+/).first(MAX_SEARCH_WORDS)
        return [] if words.empty?

        # Build AND conditions: each word must appear in description OR comments
        conditions = []
        binds = {}

        words.each_with_index do |word, i|
          key = :"q#{i}"
          binds[key] = "%#{sanitize_like(word)}%"
          conditions << "(creatives.description LIKE :#{key} ESCAPE '\\' " \
                        "OR comments.content LIKE :#{key} ESCAPE '\\')"
        end

        scope
          .left_joins(:comments)
          .where(conditions.join(" AND "), **binds)
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
end
