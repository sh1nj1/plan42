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

    # The comment-created fanout has one origin and many recipients. Read the
    # comment history once, then apply each recipient's topic watermark in Ruby.
    # Joining every recipient to public history made one broadcast materialise
    # recipients × comments rows before grouping.
    def self.for_users(origin:, users:)
      recipients = users.compact.uniq(&:id)
      return {} if recipients.empty?

      counts_by_user_id = counts_for_users(origin, recipients.map(&:id))
      present_user_ids = CommentPresenceStore.list(origin.id)
      viewing_topics_by_user_id = CommentPresenceStore.viewing_topics_for(origin.id, present_user_ids)
      recipients.to_h do |user|
        counts_by_topic = counts_by_user_id.fetch(user.id, {})
        viewing_topics = viewing_topics_by_user_id.fetch(user.id, [])
        unread_count = counts_by_topic.sum do |topic_id, counts|
          topic_is_viewed?(topic_id, viewing_topics) ? 0 : counts.fetch(:unread)
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

      present_origin_ids = CommentPresenceStore.list_many(origin_ids).filter_map do |origin_id, present_user_ids|
        origin_id if present_user_ids.include?(user.id)
      end
      viewing_topics_by_origin_id = CommentPresenceStore.viewing_topics_for_creatives(user.id, present_origin_ids)

      present_origin_ids.each do |origin_id|
        origin = Creative.find_by(id: origin_id)
        next unless origin

        all_counts = unread_counts_by_topic_without_presence(origin)
        remaining_counts = all_counts.dup
        suppress_viewing_topics!(remaining_counts, origin, viewing_topics: viewing_topics_by_origin_id.fetch(origin_id, []))
        @unread_by_origin_id[origin_id] -= all_counts.values.sum - remaining_counts.values.sum
      end
    end

    def suppress_viewing_topics!(counts, origin, viewing_topics: CommentPresenceStore.viewing_topics(origin.id, user.id))
      if viewing_topics.include?(CommentPresenceStore::ALL_TOPICS)
        # All Messages renders Main and the active-topic snapshot returned with
        # its list. A topic restored after that response stays unread until the
        # list is reloaded and reports it in a new snapshot.
        counts.delete(nil) if viewing_topics.include?(CommentPresenceStore::LEGACY_TOPIC)
      end

      # Another subscription can be viewing an archived topic while this one is
      # on All Messages. Suppress every explicitly rendered topic as well.
      viewing_topics.excluding(CommentPresenceStore::ALL_TOPICS).each { |topic_id| counts.delete(topic_id) }
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

      # A comment broadcast can fan out to many people. Keep the comment scan
      # independent of recipient count, then count the suffix after each
      # watermark with a binary search. The arrays are ordered by primary key
      # because find_each advances by that key.
      def counts_for_users(origin, user_ids)
        recipient_ids = user_ids.to_h { |user_id| [ user_id, true ] }
        watermarks_by_user_id = read_watermarks_for_users(origin, user_ids)
        public_comment_ids_by_topic = Hash.new { |hash, topic_id| hash[topic_id] = [] }
        private_comment_ids_by_user_id = Hash.new { |hash, user_id| hash[user_id] = Hash.new { |topics, topic_id| topics[topic_id] = [] } }

        Comment.where(creative_id: origin.id).select(:id, :topic_id, :private, :user_id, :approver_id).find_each(batch_size: QUERY_BATCH_SIZE) do |comment|
          if comment.private?
            [ comment.user_id, comment.approver_id ].compact.uniq.each do |user_id|
              private_comment_ids_by_user_id[user_id][comment.topic_id] << comment.id if recipient_ids.include?(user_id)
            end
          else
            public_comment_ids_by_topic[comment.topic_id] << comment.id
          end
        end

        user_ids.each_with_object({}) do |user_id, counts_by_user_id|
          topic_ids = public_comment_ids_by_topic.keys | private_comment_ids_by_user_id[user_id].keys
          counts_by_user_id[user_id] = topic_ids.each_with_object({}) do |topic_id, counts_by_topic|
            watermark = watermark_for(watermarks_by_user_id[user_id], topic_id)
            public_ids = public_comment_ids_by_topic[topic_id]
            private_ids = private_comment_ids_by_user_id[user_id][topic_id]
            counts_by_topic[topic_id] = {
              unread: count_after(public_ids, watermark) + count_after(private_ids, watermark),
              visible: public_ids.length + private_ids.length
            }
          end
        end
      end

      def read_watermarks_for_users(origin, user_ids)
        CommentReadPointer.where(user_id: user_ids, creative_id: origin.id)
          .where.not(last_read_comment_id: nil)
          .pluck(:user_id, :topic_id, :last_read_comment_id)
          .each_with_object(Hash.new { |hash, user_id| hash[user_id] = {} }) do |(user_id, topic_id, last_read_id), watermarks|
            watermarks[user_id][topic_id] = last_read_id
          end
      end

      def watermark_for(watermarks, topic_id)
        watermarks.fetch(topic_id, watermarks.fetch(nil, 0))
      end

      def count_after(comment_ids, watermark)
        first_unread_index = comment_ids.bsearch_index { |comment_id| comment_id > watermark }
        first_unread_index ? comment_ids.length - first_unread_index : 0
      end

      def topic_is_viewed?(topic_id, viewing_topics)
        return viewing_topics.include?(topic_id) unless viewing_topics.include?(CommentPresenceStore::ALL_TOPICS)

        topic_id.nil? ? viewing_topics.include?(CommentPresenceStore::LEGACY_TOPIC) : viewing_topics.include?(topic_id)
      end
    end
  end
end
end
