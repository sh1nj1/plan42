# frozen_string_literal: true

module Collavre
  module Creatives
    class HistoryPage
      def initialize(scope:, user:, before_id:, after_id:, limit:)
        @scope = scope
        @visibility = ChangeSetVisibility.new(user: user)
        @before_id = before_id.presence&.to_i
        @after_id = after_id.presence&.to_i
        @limit = limit
      end

      def call
        visible = []
        cursor = boundary

        loop do
          batch = next_batch(cursor)
          break if batch.empty?

          visible.concat(batch.select { |change_set| visible?(change_set) })
          break if visible.size >= @limit

          cursor = batch.last.id
        end

        page = visible.first(@limit)
        descending? ? page.reverse : page
      end

      private

      def next_batch(cursor)
        relation = @scope.reorder(id: descending? ? :desc : :asc)
        relation = constrained(relation, cursor) if cursor
        relation.limit(@limit).to_a
      end

      def constrained(relation, cursor)
        if descending?
          relation.where("creative_change_sets.id < ?", cursor)
        else
          relation.where("creative_change_sets.id > ?", cursor)
        end
      end

      def visible?(change_set)
        @visibility.changes(change_set.creative_changes).any?
      end

      def descending?
        @after_id.nil?
      end

      def boundary
        @after_id || @before_id
      end
    end
  end
end
