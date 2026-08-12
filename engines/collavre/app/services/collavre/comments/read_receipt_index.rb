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

        receipt_pointers = pointers.to_a
        readable_user_ids = CreativeShare.readable_user_ids_from_shares(
          creative,
          receipt_pointers.map(&:user_id)
        ).to_set
        receipt_pointers.select! { |pointer| readable_user_ids.include?(pointer.user_id) }
        receipt_users_by_comment_id = Hash.new { |hash, key| hash[key] = Set.new }

        receipt_pointers.each_with_object({}) do |pointer, result|
          next if pointer.last_read_comment_id > rendered_window_max_id

          effective_id = pointer[:receipt_comment_id]
          next unless effective_id && rendered.include?(effective_id)
          next if receipt_users_by_comment_id[effective_id].include?(pointer.user_id)

          receipt_users_by_comment_id[effective_id] << pointer.user_id
          (result[effective_id] ||= []) << pointer.user
        end
      end

      private

      attr_reader :creative, :comments

      def rendered_window_max_id
        @rendered_window_max_id ||= comments.map(&:id).max
      end

      def rendered_public_ids
        @rendered_public_ids ||= comments.reject(&:private?).map(&:id).sort
      end

      # Resolve the nearest public comment at or before each pointer in the same
      # query that loads the pointers. This stays bounded by participant count
      # even when a topic-filtered page spans thousands of hidden public comments.
      def pointers
        pointer_table = CommentReadPointer.arel_table
        named_pointer_table = CommentReadPointer.arel_table.alias("named_receipt_pointers")
        public_comments = Comment.arel_table.alias("receipt_comments")
        effective_comment_id = Comment
          .from(public_comments)
          .select(public_comments[:id].maximum)
          .where(public_comments[:creative_id].eq(pointer_table[:creative_id]))
          .where(public_comments[:private].eq(false))
          .where(matches_pointer_topic(pointer_table, named_pointer_table, public_comments))
          .where(public_comments[:id].lteq(pointer_table[:last_read_comment_id]))
          .arel

        CommentReadPointer
          .where(creative: creative)
          .where.not(last_read_comment_id: nil)
          .select(pointer_table[Arel.star], effective_comment_id.as("receipt_comment_id"))
          .includes(user: { avatar_attachment: :blob })
      end

      # Legacy pointers represent the NULL-topic lane after the migration. They
      # can still cover a named topic that has no per-topic pointer, but never
      # override a named pointer for the same user, creative, and topic.
      def matches_pointer_topic(pointer_table, named_pointer_table, public_comments)
        named_pointer_exists = CommentReadPointer
          .unscoped
          .from(named_pointer_table)
          .select(Arel.sql("1"))
          .where(named_pointer_table[:user_id].eq(pointer_table[:user_id]))
          .where(named_pointer_table[:creative_id].eq(pointer_table[:creative_id]))
          .where(named_pointer_table[:topic_id].eq(public_comments[:topic_id]))
          .where(named_pointer_table[:topic_id].not_eq(nil))
          .arel.exists

        legacy_match = public_comments[:topic_id].eq(nil).or(named_pointer_exists.not)
        pointer_table[:topic_id].eq(nil).and(legacy_match).or(
          pointer_table[:topic_id].not_eq(nil).and(pointer_table[:topic_id].eq(public_comments[:topic_id]))
        )
      end
    end
  end
end
