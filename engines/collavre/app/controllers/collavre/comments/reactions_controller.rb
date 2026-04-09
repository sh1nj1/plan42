module Collavre
  module Comments
    class ReactionsController < ApplicationController
      include Collavre::Comments::CommentScoping

      before_action :set_creative
      before_action :set_comment
      before_action :authorize_feedback!

      def create
        emoji = params[:emoji].to_s.strip
        if emoji.blank?
          render json: { error: I18n.t("collavre.comments.reaction_invalid") }, status: :unprocessable_entity and return
        end

        @comment.comment_reactions.find_or_create_by!(user: Current.user, emoji: emoji)
        broadcast_reaction_update
        render json: build_reaction_payload
      end

      def destroy
        emoji = params[:emoji].to_s.strip
        if emoji.blank?
          render json: { error: I18n.t("collavre.comments.reaction_invalid") }, status: :unprocessable_entity and return
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
        CommentReaction.broadcast_reaction_update(@comment)
      end

      def authorize_feedback!
        return if @creative.has_permission?(Current.user, :feedback)

        render json: { error: I18n.t("collavre.comments.no_permission") }, status: :forbidden
      end
    end
  end
end
