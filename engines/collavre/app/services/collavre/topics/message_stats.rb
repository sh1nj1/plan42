# frozen_string_literal: true

module Collavre
  module Topics
    # Per-topic message totals for a set of topics, in one grouped query.
    #
    # This is the call that makes fan-out planning possible: before an agent
    # spends its context on message bodies it asks how much there is, and
    # decides how to chunk. Counting by loading is exactly what that is meant to
    # avoid, so nothing here instantiates a Comment.
    module MessageStats
      Stat = Struct.new(:count, :chars, :last_at, keyword_init: true)

      EMPTY = Stat.new(count: 0, chars: 0, last_at: nil).freeze

      module_function

      # Returns { topic_id => Stat }, with EMPTY for topics that have no
      # visible messages (a grouped query returns no row for them at all).
      #
      # `chars` is LENGTH over the stored content, which is HTML — an upper
      # bound on the plain text a page will actually return, not the exact
      # figure. Getting the exact figure means stripping every body, which is
      # the load this query exists to avoid. Callers that need a true rate can
      # divide a returned page's own plain-text length by its message count.
      # max_message_id must reach the totals as well as the window. has_more? is
      # (offset + returned) < total, so a total counting past the anchor would
      # keep claiming there is another page after the snapshot has been fully
      # read — the caller pages forever against rows its anchor excludes.
      def for(topics, user:, include_system: false, max_message_id: nil)
        topics = Array(topics)
        return {} if topics.empty?

        rows = grouped_rows(topics.map(&:id), user: user, include_system: include_system,
                            max_message_id: max_message_id)
        totals = rows.to_h do |topic_id, count, chars, last_at|
          [ topic_id, Stat.new(count: count.to_i, chars: chars.to_i, last_at: as_time(last_at)) ]
        end

        topics.to_h { |topic| [ topic.id, totals[topic.id] || EMPTY ] }
      end

      # An aggregate selected through Arel.sql carries no column type, so the
      # adapter hands MAX(created_at) back as the raw driver value — a String on
      # Postgres. Callers expect a Time they can format, so normalize here
      # rather than at each of them.
      def as_time(value)
        return value if value.nil? || value.is_a?(Time)

        Time.zone.parse(value.to_s)
      end

      def grouped_rows(topic_ids, user:, include_system:, max_message_id: nil)
        MessageScope.for_ids(
          topic_ids, user: user, include_system: include_system, max_message_id: max_message_id
        ).group(:topic_id).pluck(
          :topic_id,
          Arel.sql("COUNT(*)"),
          Arel.sql("COALESCE(SUM(LENGTH(comments.content)), 0)"),
          Arel.sql("MAX(comments.created_at)")
        )
      end
    end
  end
end
