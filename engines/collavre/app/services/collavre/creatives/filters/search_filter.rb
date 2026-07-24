module Collavre
module Creatives
  module Filters
    class SearchFilter < BaseFilter
      MAX_SEARCH_WORDS = 5

      def active?
        params[:search].present?
      end

      def match
        matched_relation&.pluck(:id) || []
      end

      # The matching rows as an ActiveRecord relation (ids not yet materialized),
      # so callers that need to order/window in SQL can wrap it as a subquery
      # instead of plucking the whole match set into Ruby first. Returns nil when
      # the search has no usable terms. Keeps the left_joins(:comments).distinct
      # shape (a creative matches when one comment row satisfies every word
      # together with the description) — an EXISTS rewrite would change that
      # semantics, so it stays a joined+distinct relation.
      def matched_relation
        words = params[:search].to_s.strip.split(/\s+/).first(MAX_SEARCH_WORDS)
        return nil if words.empty?

        # Build AND conditions: each word must appear in description OR comments
        conditions = []
        binds = {}

        words.each_with_index do |word, i|
          key = :"q#{i}"
          binds[key] = "%#{sanitize_like(word.downcase)}%"
          conditions << "(LOWER(creatives.description) LIKE :#{key} ESCAPE '\\' " \
                        "OR LOWER(comments.content) LIKE :#{key} ESCAPE '\\')"
        end

        scope
          .left_joins(:comments)
          .where(conditions.join(" AND "), **binds)
          .distinct
      end

      private

      def sanitize_like(str)
        ActiveRecord::Base.sanitize_sql_like(str.to_s)
      end
    end
  end
end
end
