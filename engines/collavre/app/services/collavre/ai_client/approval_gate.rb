# frozen_string_literal: true

module Collavre
  class AiClient
    module ApprovalGate
      private

      def prepare_gate_conversation(contents, tools)
        start_usage_tracking
        @conversation = build_conversation(tools)
        install_usage_tracking(@conversation)
        add_messages(@conversation, contents) unless restore_approval_gate
      end

      def install_tool_boundary(chat)
        chat.on_tool_call do |tool_call|
          # Cancellation ahead of the approval gate: a turn that already
          # reached a terminal status or its deadline must end, not park
          # itself as pending approval for a tool it will never run. Force this
          # boundary through the lifecycle throttle: the first tool call can
          # arrive during the manager's initial one-second quiet period.
          @before_tool_call&.call(true)
          check_tool_approval!(tool_call)
          start_tool_usage(tool_call)
        end
        # Registered before build_conversation's boundary refresh, which can raise on deadline.
        chat.after_tool_result { |result| finish_tool_usage(!ToolUsage.failed_result?(result)) }
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
