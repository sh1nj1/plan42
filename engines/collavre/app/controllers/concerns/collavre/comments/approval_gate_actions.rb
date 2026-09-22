# frozen_string_literal: true

module Collavre
  module Comments
    module ApprovalGateActions
      extend ActiveSupport::Concern

      included do
        before_action :prevent_gate_action_edit, only: :update_action
      end
      private

      def prevent_gate_action_edit
        render_approval_status_error(:not_allowed) if @comment.approval_gate?
      end

      def decide_approval_gate(decision)
        status = @comment.approval_status(Current.user)
        return render_approval_status_error(status) unless status == :ok

        ApprovalGateDecision.new(@comment, Current.user).call(decision, reason: params[:reason])
        @comment.reload
        render partial: "collavre/comments/comment", formats: [ :html ], locals: { comment: @comment, current_topic_id: current_topic_context }
      rescue ApprovalGateDecision::InvalidDecision => e
        render json: { error: e.message }, status: :unprocessable_entity
      end
    end
  end
end
