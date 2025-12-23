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
    broadcast_reaction_update
    render json: build_reaction_payload
  end

  def destroy
    emoji = params[:emoji].to_s.strip
    if emoji.blank?
      render json: { error: I18n.t("comments.reaction_invalid") }, status: :unprocessable_entity and return
    end

    reaction = @comment.comment_reactions.find_by(user: Current.user, emoji: emoji)
    reaction&.destroy
    broadcast_reaction_update
    render json: build_reaction_payload
  end

  private

  def build_reaction_payload
    # Fetch fresh reactions
    reactions = @comment.comment_reactions.reload.to_a
    reaction_groups = reactions.group_by(&:emoji)

    reaction_groups.map do |emoji, grouped_reactions|
      {
        emoji: emoji,
        count: grouped_reactions.size,
        user_ids: grouped_reactions.map(&:user_id)
      }
    end
  end

  def broadcast_reaction_update
    payload = build_reaction_payload
    Turbo::StreamsChannel.broadcast_action_to(
      [ @creative, :comments ],
      action: "update_reactions",
      target: view_context.dom_id(@comment),
      attributes: {
        data: payload.to_json
      }
    )
  end

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
end
