module Collavre
  class CommentMoveService
    class MoveError < StandardError; end

    def initialize(creative:, user:)
      @creative = creative
      @user = user
    end

    # Returns { success: true, moved_count: N }
    # Raises MoveError on validation failures
    def call(comment_ids:, target_creative_id: nil, target_topic_id: nil)
      comment_ids = Array(comment_ids).map(&:presence).compact.map(&:to_i)
      raise MoveError, I18n.t("collavre.comments.move_no_selection") if comment_ids.empty?

      target_origin, new_topic_id = resolve_target(target_creative_id, target_topic_id)

      validate_permissions!(target_origin)
      comments = fetch_visible_comments(comment_ids)

      moved_count = perform_move(comments, target_origin, new_topic_id)

      Comment.broadcast_badges_later(@creative)
      Comment.broadcast_badges_later(target_origin) unless target_origin == @creative

      { success: true, moved_count: moved_count }
    end

    private

    attr_reader :creative, :user

    def resolve_target(target_creative_id, target_topic_id)
      if target_creative_id.present?
        target_creative = Creative.find_by(id: target_creative_id)
        raise MoveError, I18n.t("collavre.comments.move_invalid_target") unless target_creative
        target_origin = target_creative.effective_origin
        [ target_origin, target_origin.main_topic.id ]
      elsif !target_topic_id.nil?
        new_topic_id = target_topic_id.presence
        if new_topic_id.present? && !creative.topics.exists?(id: new_topic_id)
          raise MoveError, I18n.t("collavre.comments.move_invalid_topic", default: "Invalid topic")
        end
        [ creative, new_topic_id || creative.main_topic.id ]
      else
        raise MoveError, I18n.t("collavre.comments.move_invalid_target")
      end
    end

    def validate_permissions!(target_origin)
      unless creative.has_permission?(user, :feedback) && target_origin.has_permission?(user, :feedback)
        raise MoveError, I18n.t("collavre.comments.move_not_allowed")
      end
    end

    def fetch_visible_comments(comment_ids)
      scope = creative.comments.visible_to(user)
      comments = scope.where(id: comment_ids).to_a
      raise MoveError, I18n.t("collavre.comments.move_not_allowed") if comments.length != comment_ids.length
      comments
    end

    def perform_move(comments, target_origin, new_topic_id)
      moved_count = 0
      ActiveRecord::Base.transaction do
        comments.each do |comment|
          same_creative = comment.creative_id == target_origin.id
          same_topic = comment.topic_id.to_s == new_topic_id.to_s
          next if same_creative && same_topic

          if same_creative
            preserve_unread_state_for_topic_move(comment, new_topic_id)
            comment.update!(topic_id: new_topic_id)
          else
            preserve_unread_state_for_topic_move(
              comment,
              new_topic_id || target_origin.main_topic.id,
              destination_creative: target_origin
            )
            comment.update!(creative: target_origin, topic_id: new_topic_id)
            broadcast_move_removal(comment, comment.creative)
          end
          moved_count += 1
        end
      end
      moved_count
    end

    # A topic watermark is an ordered cursor, so a comment moved into a topic
    # whose cursor is already beyond its id would otherwise become read without
    # the recipient seeing it. Lower only affected recipients' destination
    # cursor to just before the moved comment; this is deliberately
    # conservative and may re-show later destination comments as unread.
    def preserve_unread_state_for_topic_move(comment, destination_topic_id, destination_creative: creative)
      source_topic_id = comment.topic_id
      readable_user_ids = CreativeShare.readable_user_ids_from_shares(
        destination_creative,
        readers_affected_by(comment, destination_creative)
      )
      readable_user_ids.each do |user_id|
        source_pointers = CommentReadPointer.where(user_id: user_id, creative: creative).index_by(&:topic_id)
        destination_pointers = if destination_creative == creative
          source_pointers
        else
          CommentReadPointer.where(user_id: user_id, creative: destination_creative).index_by(&:topic_id)
        end
        source_watermark = source_pointers[source_topic_id]&.last_read_comment_id || source_pointers[nil]&.last_read_comment_id || 0
        destination_watermark = destination_pointers[destination_topic_id]&.last_read_comment_id || destination_pointers[nil]&.last_read_comment_id || 0
        next unless source_watermark < comment.id && destination_watermark >= comment.id

        destination_pointer = destination_pointers[destination_topic_id] || CommentReadPointer.find_or_create_by!(
          user_id: user_id, creative: destination_creative, topic_id: destination_topic_id
        )
        destination_pointer.update!(last_read_comment_id: comment.id - 1)
      end
    end

    # Private comments are visible only to their author and approver. Rewinding
    # another user's cursor would make unrelated destination comments unread.
    def readers_affected_by(comment, destination_creative)
      reader_ids = CommentReadPointer.where(creative: [ creative, destination_creative ]).distinct.pluck(:user_id)
      return reader_ids unless comment.private?

      reader_ids & [ comment.user_id, comment.approver_id ].compact
    end

    def broadcast_move_removal(comment, original_creative)
      return if comment.private?

      Turbo::StreamsChannel.broadcast_remove_to(
        [ original_creative, :comments ],
        target: ActionView::RecordIdentifier.dom_id(comment)
      )
    end
  end
end
