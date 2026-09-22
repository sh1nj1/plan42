# frozen_string_literal: true

module Collavre
  class AiClient
    module ApprovalGate
      private

      def prepare_gate_conversation(contents, tools)
        @conversation = build_conversation(tools)
        add_messages(@conversation, contents) unless restore_approval_gate
      end

      def check_approval_gate!(tool_call)
        args = approval_gate_arguments(tool_call)
        return unless args

        task = context&.dig(:task)
        approver = gate_approver(task, args)
        return unless approver
        raise ApprovalGatePendingError.new(
          tool_call: tool_call, task: task, question: args["question"], approver: approver,
          messages: AiAgent::ApprovalConversation.dump(@conversation.messages)
        )
      end

      def gate_approver(task, args)
        Tools::ApprovalRequestService.approver!(task, args["question"], args["approver_user_id"])
      rescue ArgumentError
        # Let the tool return validation errors so the model can correct its call.
        nil
      end

      def approval_gate_arguments(tool_call)
        args = tool_call.arguments.to_h.stringify_keys
        return args if tool_call.name == "approval_request"
        return unless tool_call.name == "meta_tool" && args["action"] == "run"
        return unless args["tool_name"] == "approval_request"

        (args["arguments"] || {}).stringify_keys
      end

      def restore_approval_gate
        pending = context&.dig(:task)&.pending_tool_call
        return false unless pending&.dig("kind") == "approval_gate"
        raise CancelledError unless pending["decision"]

        AiAgent::ApprovalConversation.restore(@conversation, pending)
        true
      end
    end
  end
end
