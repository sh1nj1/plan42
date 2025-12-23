class Comments::ReactionsController < ApplicationController
  before_action :set_creative
  before_action :set_comment
  before_action :authorize_feedback!

  def create
    emoji = params[:emoji].to_s.strip
    if emoji.blank?
      render json: { error: I18n.t("comments.reaction_invalid") }, status: :unprocessable_entity and return
    end

    @comment.comment_reactions.find_or_create_by!(user: Current.user, emoji: emoji)
    render_comment
  end

  def destroy
    emoji = params[:emoji].to_s.strip
    if emoji.blank?
      render json: { error: I18n.t("comments.reaction_invalid") }, status: :unprocessable_entity and return
    end

    reaction = @comment.comment_reactions.find_by(user: Current.user, emoji: emoji)
    reaction&.destroy
    render_comment
  end

  private

  def set_creative
    @creative = Creative.find(params[:creative_id]).effective_origin
  end

  def set_comment
    comment_id = params[:comment_id] || params[:id]
    @comment = @creative.comments
                       .where(
                         "comments.private = ? OR comments.user_id = ? OR comments.approver_id = ?",
                         false,
                         Current.user.id,
                         Current.user.id
                       )
                       .find(comment_id)
  end

  def authorize_feedback!
    return if @creative.has_permission?(Current.user, :feedback)

    render json: { error: I18n.t("comments.no_permission") }, status: :forbidden
  end

  def render_comment
    @comment = Comment.with_attached_images.includes(:comment_reactions).find(@comment.id)
    render partial: "comments/comment", locals: { comment: @comment, current_topic_id: params[:topic_id] }
  end
end
