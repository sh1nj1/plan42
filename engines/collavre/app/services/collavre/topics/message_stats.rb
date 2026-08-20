# frozen_string_literal: true

module Collavre
  module Topics
    # Per-topic message totals for a set of topics, in grouped aggregate queries.
    #
    # This is the call that makes fan-out planning possible: before an agent
    # spends its context on message bodies it asks how much there is, and
    # decides how to chunk. Counting by loading is exactly what that is meant to
    # avoid, so nothing here instantiates a Comment.
    module MessageStats
      Stat = Struct.new(:count, :chars, :last_at, keyword_init: true)

      # Marker prose, attachment index, byte-size digits, separators and the
      # signed-id path are bounded conservatively here. Filename is charged
      # twice because it appears in both the label and URL; content type and a
      # configured public-assets host are charged at their actual lengths.
      ATTACHMENT_MARKER_OVERHEAD_CHARS = 300

      EMPTY = Stat.new(count: 0, chars: 0, last_at: nil).freeze

      module_function

      # Returns { topic_id => Stat }, with EMPTY for topics that have no
      # visible messages (a grouped query returns no row for them at all).
      #
      # `chars` combines LENGTH over the stored HTML with a conservative image
      # marker estimate. It remains a planning estimate rather than an exact
      # rendered size: exact text requires stripping every body, which is the
      # load this query exists to avoid.
      # max_message_id must reach the totals as well as the window. has_more? is
      # (offset + returned) < total, so a total counting past the anchor would
      # keep claiming there is another page after the snapshot has been fully
      # read — the caller pages forever against rows its anchor excludes.
      def for(topics, user:, include_system: false, max_message_id: nil)
        topics = Array(topics)
        return {} if topics.empty?

        scope = MessageScope.for_ids(
          topics.map(&:id), user: user, include_system: include_system, max_message_id: max_message_id
        )
        rows = grouped_rows(scope)
        attachment_chars = attachment_chars_by_topic(scope)
        totals = rows.to_h do |topic_id, count, chars, last_at|
          total_chars = chars.to_i + attachment_chars.fetch(topic_id, 0)
          [ topic_id, Stat.new(count: count.to_i, chars: total_chars, last_at: as_time(last_at)) ]
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

      def grouped_rows(scope)
        scope.group(:topic_id).pluck(
          :topic_id,
          Arel.sql("COUNT(*)"),
          Arel.sql("COALESCE(SUM(LENGTH(comments.content)), 0)"),
          Arel.sql("MAX(comments.created_at)")
        )
      end

      def attachment_chars_by_topic(scope)
        host_chars = Collavre::IntegrationSettings.fetch(:public_assets_host).to_s.length

        attachment_rows(scope).to_h do |topic_id, count, filename_chars, content_type_chars|
          estimate = count.to_i * (ATTACHMENT_MARKER_OVERHEAD_CHARS + host_chars) +
            filename_chars.to_i * 2 + content_type_chars.to_i
          [ topic_id, estimate ]
        end
      end

      def attachment_rows(scope)
        scope.joins(images_attachments: :blob).group(:topic_id).pluck(
          :topic_id,
          Arel.sql("COUNT(active_storage_attachments.id)"),
          Arel.sql("COALESCE(SUM(LENGTH(active_storage_blobs.filename)), 0)"),
          Arel.sql("COALESCE(SUM(LENGTH(active_storage_blobs.content_type)), 0)")
        )
      end
    end
  end
end
