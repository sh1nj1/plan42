# frozen_string_literal: true

module Collavre
  module Comments
    # Which participants' avatars sit under which comment of the page being
    # rendered.
    #
    # A read pointer names the last comment a user read, which may be private or
    # in another topic and therefore not on screen. The receipt is drawn on the
    # nearest *public* comment at or before it — so the mapping needs to know
    # about public comments the page itself does not render.
    #
    # It does NOT need to load any public-comment id list. Each read pointer can
    # resolve its effective public comment with a correlated MAX(id) subquery,
    # which PostgreSQL and SQLite both serve from the public-comment index. The
    # outer query still returns only one row per participant, while the rendered
    # id set decides whether that receipt belongs on this page.
    class ReadReceiptIndex
      def initialize(creative:, comments:)
        @creative = creative
        @comments = Array(comments)
      end

      # => { comment_id => [User, ...] }, keyed only by comments in `comments`.
      def receipts
        return {} if rendered_public_ids.empty?

        rendered = rendered_public_ids.to_set

        pointers.each_with_object({}) do |pointer, result|
          effective_id = pointer[:receipt_comment_id]
          next unless effective_id && rendered.include?(effective_id)

          (result[effective_id] ||= []) << pointer.user
        end
      end

      private

      attr_reader :creative, :comments

      def rendered_public_ids
        @rendered_public_ids ||= comments.reject(&:private?).map(&:id).sort
      end

      # Resolve the nearest public comment at or before each pointer in the same
      # query that loads the pointers. This stays bounded by participant count
      # even when a topic-filtered page spans thousands of hidden public comments.
      def pointers
        pointer_table = CommentReadPointer.arel_table
        public_comments = Comment.arel_table.alias("receipt_comments")
        effective_comment_id = Comment
          .from(public_comments)
          .select(public_comments[:id].maximum)
          .where(public_comments[:creative_id].eq(pointer_table[:creative_id]))
          .where(public_comments[:private].eq(false))
          .where(public_comments[:id].lteq(pointer_table[:last_read_comment_id]))
          .arel

        CommentReadPointer
          .where(creative: creative)
          .where.not(last_read_comment_id: nil)
          .select(pointer_table[Arel.star], effective_comment_id.as("receipt_comment_id"))
          .includes(user: { avatar_attachment: :blob })
      end
    end
  end
end
