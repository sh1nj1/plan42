# frozen_string_literal: true

module Collavre
  module AiAgent
    # Manages agent lifecycle during task execution:
    # - Status broadcasting (thinking, streaming, idle)
    # - Cancellation checking
    # - Heartbeat management
    class AgentLifecycleManager
      # Minimum interval (in seconds) between cancellation checks to avoid excessive DB queries
      CANCEL_CHECK_INTERVAL = 1.0
      # Interval (in seconds) between agent_status heartbeats during streaming
      AGENT_STATUS_HEARTBEAT_INTERVAL = 3.0

      def initialize(task:, agent:, creative:)
        @task = task
        @agent = agent
        @creative = creative
        @last_cancel_check_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        @last_heartbeat_at = @last_cancel_check_at
      end

      # Broadcast agent status change
      def broadcast_status(status, content: nil)
        return unless @creative

        CommentsPresenceChannel.broadcast_agent_status(
          @creative.effective_origin.id,
          status: status,
          agent_id: @agent.id,
          agent_name: @agent.display_name,
          task_id: @task.id,
          content: content,
          source_creative_id: @creative.id
        )
      end

      # Check if task was cancelled, raise Collavre::CancelledError if so
      def check_cancelled!
        now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        return if (now - @last_cancel_check_at) < CANCEL_CHECK_INTERVAL

        @last_cancel_check_at = now
        raise Collavre::CancelledError if @task.reload.status == "cancelled"
      end

      # Send heartbeat if interval passed
      def heartbeat_if_needed
        now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        if (now - @last_heartbeat_at) >= AGENT_STATUS_HEARTBEAT_INTERVAL
          broadcast_status("streaming")
          @last_heartbeat_at = now
        end
      end

      # Handle cancellation cleanup
      def handle_cancelled(reply_comment:, response_content:)
        if reply_comment
          if response_content.present?
            reply_comment.content_will_change!
            reply_comment.update!(content: response_content)
            reply_comment.broadcast_update_to(
              [ reply_comment.creative, :comments ],
              partial: "collavre/comments/comment",
              locals: { comment: reply_comment, streaming: false }
            )
            log_action("reply_created", { comment_id: reply_comment.id, content: response_content, partial: true })
          else
            reply_comment.destroy!
          end
        end

        broadcast_status("idle")
        log_action("cancelled", { message: "Task cancelled by user" })
      end

      private

      def log_action(type, payload, result = nil)
        @task.task_actions.create!(
          action_type: type,
          payload: payload,
          result: result,
          status: "done"
        )
      end
    end
  end
end
