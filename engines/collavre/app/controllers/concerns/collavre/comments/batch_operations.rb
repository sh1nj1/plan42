module Collavre
  module Comments
    module BatchOperations
      extend ActiveSupport::Concern

      MAX_BATCH_DELETE = 100

      def batch_destroy
        comment_ids = Array(params[:comment_ids]).map(&:to_i).uniq.first(MAX_BATCH_DELETE)
        if comment_ids.empty?
          render json: { error: I18n.t("collavre.comments.batch_delete_no_selection") }, status: :unprocessable_entity and return
        end

        is_admin = @creative.has_permission?(Current.user, :admin)
        is_creative_owner = @creative.user == Current.user

        visible_scope = @creative.comments.where(
          "comments.private = ? OR comments.user_id = ? OR comments.approver_id = ?",
          false, Current.user.id, Current.user.id
        )
        comments = visible_scope.where(id: comment_ids).to_a

        if comments.length != comment_ids.length
          render json: { error: I18n.t("collavre.comments.batch_delete_not_found") }, status: :not_found and return
        end

        # Check permissions: user must own all comments, or be admin/creative owner
        unless is_admin || is_creative_owner
          unauthorized = comments.reject { |c| c.user == Current.user }
          if unauthorized.any?
            render json: { error: I18n.t("collavre.comments.not_owner") }, status: :forbidden and return
          end
        end

        Comment.where(id: comments.map(&:id)).destroy_all

        head :no_content
      end

      def merge
        comment_ids = Array(params[:comment_ids]).map(&:to_i).uniq
        if comment_ids.size < 2
          render json: { error: I18n.t("collavre.comments.merge.minimum_required") }, status: :unprocessable_entity and return
        end

        unless @creative.has_permission?(Current.user, :feedback)
          render json: { error: I18n.t("collavre.comments.merge.not_authorized") }, status: :forbidden and return
        end

        visible_scope = @creative.comments.where(
          "comments.private = ? OR comments.user_id = ? OR comments.approver_id = ?",
          false, Current.user.id, Current.user.id
        )
        comments = visible_scope.where(id: comment_ids).to_a

        if comments.length != comment_ids.length
          render json: { error: I18n.t("collavre.comments.batch_delete_not_found") }, status: :not_found and return
        end

        # All comments must belong to the current user or their AI agents
        my_ai_agent_ids = Current.user.created_ai_users.pluck(:id)
        allowed_user_ids = [ Current.user.id ] + my_ai_agent_ids
        unauthorized = comments.reject { |c| allowed_user_ids.include?(c.user_id) }
        if unauthorized.any?
          render json: { error: I18n.t("collavre.comments.merge.own_messages_only") }, status: :forbidden and return
        end

        MergeCommentsJob.perform_later(@creative.id, comment_ids, Current.user.id)
        render json: { message: I18n.t("collavre.comments.merge.started") }, status: :accepted
      end

      def move
        result = CommentMoveService.new(creative: @creative, user: Current.user).call(
          comment_ids: params[:comment_ids],
          target_creative_id: params[:target_creative_id],
          target_topic_id: params[:target_topic_id]
        )
        render json: result
      rescue CommentMoveService::MoveError => e
        status = e.message == I18n.t("collavre.comments.move_not_allowed") ? :forbidden : :unprocessable_entity
        render json: { error: e.message }, status: status
      rescue ActiveRecord::RecordInvalid => e
        render json: { error: e.record.errors.full_messages.to_sentence.presence || I18n.t("collavre.comments.move_error") }, status: :unprocessable_entity
      end
    end
  end
end
