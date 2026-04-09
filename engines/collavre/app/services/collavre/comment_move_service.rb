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

      Comment.broadcast_badges(@creative)
      Comment.broadcast_badges(target_origin) unless target_origin == @creative

      { success: true, moved_count: moved_count }
    end

    private

    attr_reader :creative, :user

    def resolve_target(target_creative_id, target_topic_id)
      if target_creative_id.present?
        target_creative = Creative.find_by(id: target_creative_id)
        raise MoveError, I18n.t("collavre.comments.move_invalid_target") unless target_creative
        [ target_creative.effective_origin, nil ]
      elsif !target_topic_id.nil?
        new_topic_id = target_topic_id.presence
        if new_topic_id.present? && !creative.topics.exists?(id: new_topic_id)
          raise MoveError, I18n.t("collavre.comments.move_invalid_topic", default: "Invalid topic")
        end
        [ creative, new_topic_id ]
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
            comment.update!(topic_id: new_topic_id)
          else
            comment.update!(creative: target_origin, topic_id: new_topic_id)
            broadcast_move_removal(comment, comment.creative)
          end
          moved_count += 1
        end
      end
      moved_count
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
