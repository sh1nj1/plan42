# frozen_string_literal: true

module Collavre
  module Tools
    class ApprovalRequestService
      extend T::Sig
      extend ToolMeta

      tool_name "approval_request"
      tool_description "Pause the current native Collavre agent turn for a human decision. " \
        "Provide a concrete question and optionally a human approver ID (defaults to the triggering comment author). " \
        "The original call receives approved or denied, reason, and decided_by after the person responds. " \
        "Denial is a normal result; reconsider the plan instead of performing the denied action. No automatic expiration. " \
        "Available through native agent tools or meta_tool run; external MCP sessions are not supported " \
        "(a Claude Channel session asks through its own plugin's approval_request tool instead)."
      tool_param :question, description: "The concrete question for the human approver. Markdown supported."
      tool_param :approver_user_id, description: "Human approver with access to this creative.", required: false

      def self.requires_approval?
        false
      end

      sig { params(question: String, approver_user_id: T.nilable(Integer)).returns(T::Hash[Symbol, T.untyped]) }
      def call(question:, approver_user_id: nil)
        self.class.approver!(Current.agent_turn&.dig(:task), question, approver_user_id)
        # Valid native calls are intercepted before execution. Other callers
        # have no resumable conversation, even if they carry an agent context.
        { error: I18n.t("collavre.approval_gate.native_required") }
      rescue ArgumentError => e
        { error: e.message }
      end

      def self.approver!(task, question, approver_user_id)
        raise ArgumentError, I18n.t("collavre.approval_gate.question_required") if question.blank?
        raise ArgumentError, I18n.t("collavre.approval_gate.native_required") unless task&.running?

        id = approver_user_id || task.trigger_event_payload&.dig("comment", "user_id")
        approver = User.find_by(id: id)
        creative = task.creative&.effective_origin
        unless approver && !approver.ai_user? && creative &&
            (creative.user == approver || creative.has_permission?(approver, :read))
          raise ArgumentError, I18n.t("collavre.approval_gate.invalid_approver")
        end
        approver
      end
    end
  end
end
