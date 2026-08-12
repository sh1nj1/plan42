module Collavre
module Creatives
  # Resolves the unread and visible comment counts used by every comment badge.
  # Per node this was two queries — a read-pointer lookup and an unread COUNT —
  # which is what made the browse-tree badge cost scale with the rendered tree.
  #
  # Keyed by *origin*: a linked shell shows its origin's comments.
  #
  # The counts it hands out are display-ready: they include only comments the
  # user can see and apply presence suppression in one cache round trip.
  class CommentBadgeIndex
    # SQLite permits at most 1,000 expression nodes and commonly only 999 bound
    # values. Keep the largest badge query well below both limits.
    QUERY_BATCH_SIZE = 500

    Badge = Struct.new(:unread_count, :visible_comments, keyword_init: true)

    # The comment-created fanout has one origin and many recipients. Join every
    # recipient to the comments it can see and both of its possible pointers in
    # one grouped query. This preserves the topic-watermark semantics without
    # rebuilding a one-origin index (and its cache and SQL work) per recipient.
    def self.for_users(origin:, users:)
      recipients = users.compact.uniq(&:id)
      return {} if recipients.empty?

      counts_by_user_id = counts_for_users(origin, recipients.map(&:id))
      present_user_ids = CommentPresenceStore.list(origin.id)
      viewing_topics_by_user_id = CommentPresenceStore.viewing_topics_for(origin.id, present_user_ids)
      active_topic_ids = if viewing_topics_by_user_id.values.flatten.include?(CommentPresenceStore::ALL_TOPICS)
        origin.topics.active.pluck(:id)
      else
        []
      end

      recipients.to_h do |user|
        counts_by_topic = counts_by_user_id.fetch(user.id, {})
        viewing_topics = viewing_topics_by_user_id.fetch(user.id, [])
        unread_count = counts_by_topic.sum do |topic_id, counts|
          topic_is_viewed?(topic_id, viewing_topics, active_topic_ids) ? 0 : counts.fetch(:unread)
        end

        [ user.id, Badge.new(
          unread_count: unread_count,
          visible_comments: counts_by_topic.values.sum { |counts| counts.fetch(:visible) }.positive?
        ) ]
      end
    end

    def initialize(user:)
      @user = user
      @unread_by_origin_id = {}
      @visible_by_origin_id = {}
    end

    # Tree rendering only needs unread totals. Callers that render a standalone
    # badge also need visible-comment state to decide whether a zero is shown.
    def index(origins, include_visible_counts: true)
      pending = origins.uniq(&:id).reject { |o| @unread_by_origin_id.key?(o.id) }
      return if pending.empty?

      origin_ids = pending.map(&:id)
      watermarks = read_watermarks(origin_ids)
      unread_counts = unread_counts(origin_ids, watermarks)
      origin_ids.each do |origin_id|
        @unread_by_origin_id[origin_id] = unread_counts.fetch(origin_id, 0)
      end
      @visible_by_origin_id.merge!(visible_counts(origin_ids)) if include_visible_counts

      suppress_for_present_user(pending.map(&:id))
    end

    # nil when the origin was never indexed, which tells the caller to fall back
    # to the single-creative path rather than silently render a zero badge.
    def unread_count_for(origin)
      @unread_by_origin_id[origin.id]
    end

    def visible_comments?(origin)
      @visible_by_origin_id[origin.id].to_i.positive?
    end

    # The topic strip needs the same display-ready unread state as the creative
    # badge, split by topic. A topic watermark wins; a legacy creative-wide
    # watermark is only the fallback for a topic without its own row.
    def unread_counts_by_topic(origin)
      counts = unread_counts_by_topic_without_presence(origin)
      suppress_viewing_topics!(counts, origin) if user
      counts
    end

    private

    attr_reader :user

    # One read_multi for the whole level. An anonymous visitor is never present.
    def suppress_for_present_user(origin_ids)
      return unless user

      CommentPresenceStore.list_many(origin_ids).each do |origin_id, present_user_ids|
        next unless present_user_ids.include?(user.id)

        origin = Creative.find_by(id: origin_id)
        next unless origin

        all_counts = unread_counts_by_topic_without_presence(origin)
        remaining_counts = all_counts.dup
        suppress_viewing_topics!(remaining_counts, origin)
        @unread_by_origin_id[origin_id] -= all_counts.values.sum - remaining_counts.values.sum
      end
    end

    def suppress_viewing_topics!(counts, origin)
      viewing_topics = CommentPresenceStore.viewing_topics(origin.id, user.id)
      if viewing_topics.include?(CommentPresenceStore::ALL_TOPICS)
        # All Messages renders Main plus every active topic. Archived topics are
        # intentionally excluded by CommentsController#index and stay unread.
        counts.delete(nil)
        origin.topics.active.pluck(:id).each { |topic_id| counts.delete(topic_id) }
      else
        viewing_topics.each { |topic_id| counts.delete(topic_id) }
      end
    end

    # `user_id: nil` for an anonymous visitor is the lookup the un-batched path
    # made too, so the two agree on which pointer (if any) applies.
    def read_watermarks(origin_ids)
      return {} if origin_ids.empty?

      origin_ids.each_slice(QUERY_BATCH_SIZE).each_with_object({}) do |origin_id_batch, watermarks|
        watermarks.merge!(CommentReadPointer
          .where(user_id: user&.id, creative_id: origin_id_batch)
          .where.not(last_read_comment_id: nil)
          .pluck(:creative_id, :topic_id, :last_read_comment_id)
          .each_with_object({}) do |(creative_id, topic_id, last_read_id), rows|
            (rows[creative_id] ||= {})[topic_id] = last_read_id
          end)
      end
    end

    # One grouped COUNT for the whole level. Each origin carries its own read
    # watermark, so the thresholds are OR-ed together rather than shared. Built
    # from relations rather than a SQL fragment: a hand-built string here would
    # be safe (literal template, bound values) but unprovably so to a scanner.
    def unread_counts(origin_ids, watermarks)
      origin_ids.each_slice(QUERY_BATCH_SIZE).each_with_object({}) do |origin_id_batch, counts|
        counts.merge!(unread_counts_for_batch(origin_id_batch, watermarks))
      end
    end

    def unread_counts_for_batch(origin_ids, watermarks)
      scopes = origin_ids.map { |origin_id| unread_scope(origin_id, watermarks.fetch(origin_id, {})) }
      visible_comments.merge(scopes.reduce { |combined, scope| combined.or(scope) }).group(:creative_id).count
    end

    def unread_scope(origin_id, watermarks)
      legacy_watermark = watermarks.fetch(nil, 0)
      topic_watermarks = watermarks.except(nil)
      return Comment.where(creative_id: origin_id).where(Comment.arel_table[:id].gt(legacy_watermark)) if topic_watermarks.empty?

      comment_table = Comment.arel_table
      topic_ids = topic_watermarks.keys
      fallback_scope = Comment.where(creative_id: origin_id).where(comment_table[:id].gt(legacy_watermark))
      fallback_scope = fallback_scope.where(topic_id: nil).or(fallback_scope.where.not(topic_id: topic_ids))
      topic_scopes = topic_watermarks.map do |topic_id, last_read_id|
        Comment.where(creative_id: origin_id, topic_id: topic_id).where(comment_table[:id].gt(last_read_id))
      end

      ([ fallback_scope ] + topic_scopes).reduce { |combined, scope| combined.or(scope) }
    end

    def unread_counts_by_topic_without_presence(origin)
      watermarks = read_watermarks([ origin.id ]).fetch(origin.id, {})
      visible_comments.merge(unread_scope(origin.id, watermarks)).group(:topic_id).count
    end

    def visible_counts(origin_ids)
      origin_ids.each_slice(QUERY_BATCH_SIZE).each_with_object({}) do |origin_id_batch, counts|
        counts.merge!(visible_comments.where(creative_id: origin_id_batch).group(:creative_id).count)
      end
    end

    def visible_comments
      user ? Comment.visible_to(user) : Comment.public_only
    end

    class << self
      private

      # The topic pointer is joined first; the retained creative-wide pointer
      # supplies the fallback. Starting with recipients rather than comments
      # lets the grouped result retain which user each public comment belongs
      # to, without materialising comment history in Ruby.
      def counts_for_users(origin, user_ids)
        user_table = Collavre.configuration.user_class_name.constantize.arel_table
        comment_table = Comment.arel_table
        topic_pointer_table = CommentReadPointer.arel_table.alias("topic_read_pointers")
        legacy_pointer_table = CommentReadPointer.arel_table.alias("legacy_read_pointers")

        visible_to_user = comment_table[:private].eq(false)
          .or(comment_table[:user_id].eq(user_table[:id]))
          .or(comment_table[:approver_id].eq(user_table[:id]))
        joins = user_table.join(comment_table, Arel::Nodes::InnerJoin)
          .on(comment_table[:creative_id].eq(origin.id).and(visible_to_user))
          .join(topic_pointer_table, Arel::Nodes::OuterJoin)
          .on(
            topic_pointer_table[:user_id].eq(user_table[:id])
              .and(topic_pointer_table[:creative_id].eq(origin.id))
              .and(topic_pointer_table[:topic_id].eq(comment_table[:topic_id]))
          )
          .join(legacy_pointer_table, Arel::Nodes::OuterJoin)
          .on(
            legacy_pointer_table[:user_id].eq(user_table[:id])
              .and(legacy_pointer_table[:creative_id].eq(origin.id))
              .and(legacy_pointer_table[:topic_id].eq(nil))
          )
        watermark = Arel::Nodes::NamedFunction.new(
          "COALESCE",
          [ topic_pointer_table[:last_read_comment_id], legacy_pointer_table[:last_read_comment_id], 0 ]
        )
        unread_count = Arel::Nodes::NamedFunction.new(
          "SUM",
          [ Arel::Nodes::Case.new.when(comment_table[:id].gt(watermark)).then(1).else(0) ]
        ).as("unread_count")
        visible_count = Arel::Nodes::NamedFunction.new("COUNT", [ comment_table[:id] ]).as("visible_count")

        relation = Collavre.configuration.user_class_name.constantize.where(user_table[:id].in(user_ids))
          .joins(joins.join_sources)
          .group(user_table[:id], comment_table[:topic_id])
          .select(user_table[:id], comment_table[:topic_id], unread_count, visible_count)

        relation.each_with_object(Hash.new { |hash, user_id| hash[user_id] = {} }) do |row, counts|
          counts[row.id][row.topic_id] = { unread: row.unread_count.to_i, visible: row.visible_count.to_i }
        end
      end

      def topic_is_viewed?(topic_id, viewing_topics, active_topic_ids)
        return viewing_topics.include?(topic_id) unless viewing_topics.include?(CommentPresenceStore::ALL_TOPICS)

        topic_id.nil? || active_topic_ids.include?(topic_id)
      end
    end
  end
end
end
