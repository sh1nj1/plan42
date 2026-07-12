module Collavre
module Creatives
  # Batches the browse tree's comment badge. Per node this was two queries — a
  # read-pointer lookup and an unread COUNT — which is what made the badge cost
  # scale with the size of the rendered tree.
  #
  # Keyed by *origin*: a linked shell shows its origin's comments.
  class CommentBadgeIndex
    def initialize(user:)
      @user = user
      @unread_by_origin_id = {}
    end

    def index(origins)
      pending = origins.uniq(&:id).reject { |o| @unread_by_origin_id.key?(o.id) }
      return if pending.empty?

      watermarks = read_watermarks(pending.map(&:id))

      # No read pointer means nothing has been read yet, so every comment counts
      # as unread — including private ones, matching the counter cache.
      pending.each do |origin|
        @unread_by_origin_id[origin.id] = origin.comments_count unless watermarks.key?(origin.id)
      end

      counts = unread_counts(watermarks)
      watermarks.each_key { |origin_id| @unread_by_origin_id[origin_id] = counts.fetch(origin_id, 0) }
    end

    # nil when the origin was never indexed, which tells the caller to fall back
    # to the single-creative path rather than silently render a zero badge.
    def unread_count_for(origin)
      @unread_by_origin_id[origin.id]
    end

    private

    attr_reader :user

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
    def unread_counts(watermarks)
      return {} if watermarks.empty?

      newer_than_watermark = watermarks
        .map { |origin_id, last_read_id| unread_scope(origin_id, last_read_id) }
        .reduce { |combined, scope| combined.or(scope) }

      Comment.where(private: false).merge(newer_than_watermark).group(:creative_id).count
    end

    def unread_scope(origin_id, last_read_id)
      Comment
        .where(creative_id: origin_id)
        .where(Comment.arel_table[:id].gt(last_read_id))
    end
  end
end
end
