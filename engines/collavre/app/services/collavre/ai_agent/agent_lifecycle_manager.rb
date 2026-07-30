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
      # Statuses written to the row by another process while this worker is
      # inside the provider call: user Stop -> cancelled, StuckDetectorJob ->
      # failed. Both must stop this worker — a row already settled externally
      # has nobody waiting on this turn, and streaming on holds a worker
      # thread for the rest of the provider call.
      TERMINAL_STATUSES = %w[cancelled failed].freeze

      def self.topic_id_for(task:, creative:)
        task.topic_id ||
          task.trigger_event_payload&.dig("topic", "id") ||
          Comment.where(
            id: task.trigger_event_payload&.dig("comment", "id"),
            creative_id: creative.id
          ).pick(:topic_id) ||
          creative.main_topic.id
      end

      def initialize(task:, agent:, creative:)
        @task = task
        @agent = agent
        @creative = creative
        @last_cancel_check_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        @last_heartbeat_at = @last_cancel_check_at
        # Captured once so a setting changed mid-turn cannot make the deadline
        # and the message that reports crossing it disagree about what fired.
        @turn_deadline_seconds = SystemSetting.ai_agent_turn_deadline_seconds
        @deadline_at = @last_cancel_check_at + @turn_deadline_seconds
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
          topic_id: self.class.topic_id_for(task: @task, creative: @creative),
          content: content,
          source_creative_id: @creative.id
        )
      end

      # Check if task reached a terminal status or overran its turn deadline,
      # raise Collavre::CancelledError / Collavre::TurnDeadlineError if so
      def check_cancelled!
        now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        return if (now - @last_cancel_check_at) < CANCEL_CHECK_INTERVAL

        @last_cancel_check_at = now
        raise Collavre::CancelledError if TERMINAL_STATUSES.include?(@task.reload.status)

        return if now < @deadline_at

        # This worker is the only process that knows the turn overran, so it
        # writes the terminal status itself before leaving through the
        # cancellation path (which never overwrites a terminal status).
        #
        # Written the same way StuckDetector fails a row from outside its
        # worker: mark_handed_off! has not run yet (it runs later, in
        # execute_llm_conversation's ensure), so a bare `update!` would let
        # Task's status callback decide off evidence this attempt has not
        # written down yet and restore dispatches this turn actually
        # delivered. fail_while_worker_settles! marks the row so the callback
        # defers, and AiAgentJob's ensure settles it once the real handoff
        # evidence exists.
        deadline_transitioned = Orchestration::DeliveryRecord.fail_while_worker_settles!(@task)
        # Another process may have moved the row to a terminal status after
        # the reload above but before the locked transition. Preserve that
        # winner as an ordinary cancellation; classifying it as our deadline
        # would make AiAgentJob fail a parent workflow that was just cancelled.
        raise Collavre::CancelledError unless deadline_transitioned

        Rails.logger.warn(
          "[AgentLifecycleManager] Task #{@task.id} exceeded turn deadline " \
          "(#{@turn_deadline_seconds}s); failing"
        )
        raise Collavre::TurnDeadlineError.new(@turn_deadline_seconds)
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
