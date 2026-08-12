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

      CommentReadPointer
        .where(user_id: user&.id, creative_id: origin_ids)
        .where.not(last_read_comment_id: nil)
        .pluck(:creative_id, :last_read_comment_id)
        .to_h
    end

    # One grouped COUNT for the whole level. Each origin carries its own read
    # watermark, so the thresholds are OR-ed together rather than shared. Built
    # from relations rather than a SQL fragment: a hand-built string here would
    # be safe (literal template, bound values) but unprovably so to a scanner.
    def unread_counts(origin_ids, watermarks)
      newer_than_watermark = origin_ids
        .map { |origin_id| unread_scope(origin_id, watermarks.fetch(origin_id, 0)) }
        .reduce { |combined, scope| combined.or(scope) }

      visible_comments
        .merge(newer_than_watermark)
        .group(:creative_id)
        .count
    end

    def unread_scope(origin_id, last_read_id)
      Comment
        .where(creative_id: origin_id)
        .where(Comment.arel_table[:id].gt(last_read_id))
    end

    def visible_counts(origin_ids)
      visible_comments.where(creative_id: origin_ids).group(:creative_id).count
    end

    def visible_comments
      user ? Comment.visible_to(user) : Comment.public_only
    end
  end
end
end
