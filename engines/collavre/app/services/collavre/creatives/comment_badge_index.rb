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

    # The comment-created fanout has one origin and many recipients. Keep its
    # pointer, presence, and private-comment lookups batched instead of making
    # each recipient construct a one-origin index. This deliberately mirrors
    # `Comment.visible_to(user)`: private comments are visible to their author
    # and their approver.
    def self.for_users(origin:, users:)
      user_ids = users.map(&:id).uniq
      return {} if user_ids.empty?

      pointers = CommentReadPointer.where(user_id: user_ids, creative: origin).index_by(&:user_id)
      last_read_ids = pointers.transform_values { |pointer| pointer.last_read_comment_id || 0 }
      present_user_ids = CommentPresenceStore.list(origin.id)

      any_public = origin.comments.public_only.exists?
      private_visible_counts, unread_private_counts = private_counts_for_users(origin, user_ids, last_read_ids)
      unread_public_by_threshold = unread_public_counts(origin, last_read_ids.values + [ 0 ])

      user_ids.to_h do |user_id|
        threshold = last_read_ids.fetch(user_id, 0)
        unread_count = unread_public_by_threshold.fetch(threshold, 0) + unread_private_counts.fetch(user_id, 0)
        unread_count = 0 if present_user_ids.include?(user_id)

        [ user_id, Badge.new(
          unread_count: unread_count,
          visible_comments: any_public || private_visible_counts.fetch(user_id, 0).positive?
        ) ]
      end
    end

    def initialize(user:)
      @user = user
      @unread_by_origin_id = {}
      @visible_by_origin_id = {}
    end

    def index(origins)
      pending = origins.uniq(&:id).reject { |o| @unread_by_origin_id.key?(o.id) }
      return if pending.empty?

      origin_ids = pending.map(&:id)
      watermarks = read_watermarks(origin_ids)
      unread_counts = unread_counts(origin_ids, watermarks)
      origin_ids.each do |origin_id|
        @unread_by_origin_id[origin_id] = unread_counts.fetch(origin_id, 0)
      end
      @visible_by_origin_id.merge!(visible_counts(origin_ids))

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

    private

    attr_reader :user

    # One read_multi for the whole level. An anonymous visitor is never present.
    def suppress_for_present_user(origin_ids)
      return unless user

      CommentPresenceStore.list_many(origin_ids).each do |origin_id, present_user_ids|
        @unread_by_origin_id[origin_id] = 0 if present_user_ids.include?(user.id)
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
          .pluck(:creative_id, :last_read_comment_id)
          .to_h)
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

    # Origins with no pointer all share the implicit zero watermark, so keep
    # them in one IN condition. Only origins with a real watermark need an OR.
    def unread_counts_for_batch(origin_ids, watermarks)
      without_watermark, with_watermark = origin_ids.partition { |origin_id| !watermarks.key?(origin_id) }
      scopes = []
      scopes << Comment.where(creative_id: without_watermark) if without_watermark.any?
      scopes.concat(with_watermark.map { |origin_id| unread_scope(origin_id, watermarks.fetch(origin_id)) })
      return {} if scopes.empty?

      visible_comments.merge(scopes.reduce { |combined, scope| combined.or(scope) }).group(:creative_id).count
    end

    def unread_scope(origin_id, last_read_id)
      Comment.where(creative_id: origin_id).where(Comment.arel_table[:id].gt(last_read_id))
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

      def unread_public_counts(origin, thresholds)
        thresholds.uniq.to_h do |threshold|
          [ threshold, origin.comments.public_only.where(Comment.arel_table[:id].gt(threshold)).count ]
        end
      end

      def private_counts_for_users(origin, user_ids, last_read_ids)
        visible_counts = Hash.new(0)
        unread_counts = Hash.new(0)
        user_id_set = user_ids.to_set

        origin.comments.where(private: true)
          .where("comments.user_id IN (:user_ids) OR comments.approver_id IN (:user_ids)", user_ids: user_ids)
          .pluck(:id, :user_id, :approver_id)
          .each do |comment_id, author_id, approver_id|
            [ author_id, approver_id ].compact.uniq.each do |user_id|
              next unless user_id_set.include?(user_id)

              visible_counts[user_id] += 1
              unread_counts[user_id] += 1 if comment_id > last_read_ids.fetch(user_id, 0)
            end
          end

        [ visible_counts, unread_counts ]
      end
    end
  end
end
end
