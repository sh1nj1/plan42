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
    # It does NOT need to know about all of them. The controller used to pluck
    # every public comment id of the creative on every page and every scroll,
    # which is O(whole conversation) work to place at most a handful of avatars
    # inside a 20-comment window. Only three things can happen to a pointer:
    #
    #   * older than the window     -> its receipt belongs to an earlier page
    #   * inside the window         -> resolvable from the ids in that id range
    #   * newer than the window     -> its receipt belongs to a later page
    #
    # So two bounded queries are enough: the public ids inside the window, plus
    # the first public id after it. That last one is what separates "read
    # everything we are showing" (receipt on the last rendered comment) from
    # "read past this page" (no receipt here) — without it a page of older
    # history would show every caught-up reader at its bottom.
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
          effective_id = pointer.effective_comment_id(candidate_ids)
          next unless effective_id && rendered.include?(effective_id)

          (result[effective_id] ||= []) << pointer.user
        end
      end

      private

      attr_reader :creative, :comments

      def rendered_public_ids
        @rendered_public_ids ||= comments.reject(&:private?).map(&:id).sort
      end

      # Ascending, as CommentReadPointer#effective_comment_id binary-searches it.
      # Public ids interleaved into the window but not rendered (a topic filter
      # hides them) have to be here: a pointer landing on one means the receipt
      # belongs to a comment this page is not showing.
      def candidate_ids
        @candidate_ids ||= begin
          ids = public_comments
            .where(id: rendered_public_ids.first..rendered_public_ids.last)
            .order(:id)
            .pluck(:id)
          ids << next_public_id_after_window if next_public_id_after_window
          ids
        end
      end

      def next_public_id_after_window
        return @next_public_id_after_window if defined?(@next_public_id_after_window)

        @next_public_id_after_window =
          public_comments.where(Comment.arel_table[:id].gt(rendered_public_ids.last)).minimum(:id)
      end

      def public_comments
        creative.comments.public_only
      end

      def pointers
        CommentReadPointer
          .where(creative: creative)
          .where.not(last_read_comment_id: nil)
          .includes(user: { avatar_attachment: :blob })
      end
    end
  end
end
