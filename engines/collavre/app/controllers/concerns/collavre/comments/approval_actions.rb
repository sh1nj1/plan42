module Collavre
  module Comments
    module ApprovalActions
      extend ActiveSupport::Concern

      def approve
        status = @comment.approval_status(Current.user)
        if status != :ok
          error_key = case status
          when :invalid_action_format then "collavre.comments.approve_invalid_format"
          when :missing_action then "collavre.comments.approve_missing_action"
          when :missing_approver then "collavre.comments.approve_missing_approver"
          when :admin_required then "collavre.comments.approve_admin_required"
          else "collavre.comments.approve_not_allowed"
          end
          http_status = case status
          when :invalid_action_format, :missing_action, :missing_approver
                          :unprocessable_entity
          else
                          :forbidden
          end
          render json: { error: I18n.t(error_key) }, status: http_status and return
        end

        begin
          ::Comments::ActionExecutor.new(comment: @comment, executor: Current.user).call
          @comment = Comment.with_attached_images.includes(:comment_reactions, :comment_versions, :selected_version).find(@comment.id)
          render partial: "collavre/comments/comment", locals: { comment: @comment, current_topic_id: current_topic_context }
        rescue ::Comments::ActionExecutor::ExecutionError => e
          render json: { error: e.message }, status: :unprocessable_entity
        end
      end

      def update_action
        # Initial checks outside the lock
        executed_error = false
        update_success = false
        approver_mismatch_error = false
        status_error_key = nil
        status_http_status = nil
        validation_error_message = nil

        @comment.with_lock do
          @comment.reload

          status_in_lock = @comment.approval_status(Current.user)
          # Allow repairing invalid format if user is approver
          if status_in_lock == :invalid_action_format
            if @comment.approver_id == Current.user&.id
              status_in_lock = :ok
            else
              status_in_lock = :not_allowed
            end
          end

          if status_in_lock != :ok
            approver_mismatch_error = true
            status_error_key = case status_in_lock
            when :invalid_action_format then "collavre.comments.approve_invalid_format"
            when :missing_action then "collavre.comments.approve_missing_action"
            when :missing_approver then "collavre.comments.approve_missing_approver"
            when :admin_required then "collavre.comments.approve_admin_required"
            else "collavre.comments.approve_not_allowed"
            end
            status_http_status = case status_in_lock
            when :invalid_action_format, :missing_action, :missing_approver
                            :unprocessable_entity
            else
                            :forbidden
            end
          elsif @comment.action_executed_at.present?
            executed_error = true
          else
            action_payload = params.dig(:comment, :action)
            if action_payload.blank?
              validation_error_message = I18n.t("collavre.comments.approve_missing_action")
            else
              begin
                validator = ::Comments::ActionValidator.new(comment: @comment)
                parsed_payload = validator.validate!(action_payload)
                normalized_action = JSON.pretty_generate(parsed_payload)
                update_success = @comment.update(action: normalized_action)
              rescue ::Comments::ActionValidator::ValidationError => e
                validation_error_message = e.message
              end
            end
          end
        end

        if approver_mismatch_error
          render json: { error: I18n.t(status_error_key) }, status: status_http_status
        elsif validation_error_message
          render json: { error: validation_error_message }, status: :unprocessable_entity
        elsif executed_error
          render json: { error: I18n.t("collavre.comments.approve_already_executed") }, status: :unprocessable_entity
        elsif update_success
          @comment = Comment.with_attached_images.includes(:comment_reactions, :comment_versions, :selected_version).find(@comment.id)
          render partial: "collavre/comments/comment", locals: { comment: @comment, current_topic_id: current_topic_context }
        else
          error_message = @comment.errors.full_messages.to_sentence.presence || I18n.t("collavre.comments.action_update_error")
          render json: { error: error_message }, status: :unprocessable_entity
        end
      rescue ::Comments::ActionValidator::ValidationError => e
        render json: { error: e.message }, status: :unprocessable_entity
      end
    end
  end
end
