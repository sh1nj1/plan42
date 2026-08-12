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

    # The comment-created fanout has one origin and many recipients. Each
    # recipient needs their own topic watermarks, so reuse the canonical index
    # rather than maintaining a second, creative-wide implementation here.
    def self.for_users(origin:, users:)
      users.compact.uniq(&:id).to_h do |user|
        index = new(user: user)
        index.index([ origin ])
        [ user.id, Badge.new(
          unread_count: index.unread_count_for(origin),
          visible_comments: index.visible_comments?(origin)
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
  end
end
end
