module Collavre
  module Comments
    class WorkflowExecutor
      include Concerns::WorkflowSupport

      def self.advance!(parent_task)
        new(parent_task).advance!
      end

      def initialize(parent_task)
        @parent_task = parent_task
        @state = parent_task.workflow_state || {}
      end

      def advance!
        loop do
          return if @parent_task.status == "cancelled"

          pending = @state["pending_creative_ids"] || []

          if pending.empty?
            complete_workflow!
            return
          end

          next_creative_id = pending.first
          next_creative = Creative.find_by(id: next_creative_id)

          unless next_creative
            skip_current!
            next
          end

          @state["current_creative_id"] = next_creative_id
          @parent_task.update!(workflow_state: @state)

          sub_task_context = build_subtask_context(next_creative)

          sub_task = Task.create!(
            name: "Work on: #{next_creative.description&.truncate(50)}",
            status: "pending",
            agent: @parent_task.agent,
            creative: next_creative,
            parent_task: @parent_task,
            workflow_context: @parent_task.workflow_context,
            trigger_event_name: "workflow_subtask",
            trigger_event_payload: sub_task_context,
            topic_id: nil
          )

          post_progress_notice(next_creative)
          AiAgentJob.perform_later(sub_task)
          return
        end
      end

      def complete_subtask!(sub_task)
        completed = @state["completed_creative_ids"] || []
        pending = @state["pending_creative_ids"] || []

        Rails.logger.info(
          "[WorkflowExecutor] complete_subtask! task=#{sub_task.id} creative=#{sub_task.creative_id} " \
          "pending=#{pending.inspect} completed=#{completed.inspect}"
        )

        completed << sub_task.creative_id
        pending.delete(sub_task.creative_id)

        @state["completed_creative_ids"] = completed
        @state["pending_creative_ids"] = pending
        @state["current_creative_id"] = nil
        @parent_task.update!(workflow_state: @state)

        total = @state["total"] || 1
        progress = completed.size.to_f / total
        @parent_task.creative&.update!(progress: progress.clamp(0.0, 1.0))

        Rails.logger.info(
          "[WorkflowExecutor] Progress updated: #{completed.size}/#{total} (#{(progress * 100).round}%)"
        )

        post_subtask_completed_notice(sub_task, completed.size, total)

        advance!
      end

      def fail_subtask!(sub_task, error_message: nil)
        @state["current_creative_id"] = nil
        @parent_task.update!(
          status: "failed",
          workflow_state: @state.merge(
            "failed_creative_id" => sub_task.creative_id,
            "failure_reason" => error_message
          )
        )

        post_failure_notice(sub_task, error_message)
      end

      def stop!
        # Cancel running sub-task if any
        current_sub = @parent_task.sub_tasks.where(status: %w[running queued pending]).first
        current_sub&.update!(status: "cancelled")

        @state["current_creative_id"] = nil
        @parent_task.update!(
          status: "cancelled",
          workflow_state: @state
        )

        post_notice(
          I18n.t("collavre.comments.work_command.workflow_stopped",
                 agent: @parent_task.agent.display_name,
                 completed: (@state["completed_creative_ids"] || []).size,
                 remaining: (@state["pending_creative_ids"] || []).size)
        )
      end

      def resume!
        # Re-check pending creatives — some may have been completed manually
        pending = @state["pending_creative_ids"] || []
        pending = refilter_pending(pending)
        @state["pending_creative_ids"] = pending
        @state["current_creative_id"] = nil

        # Clear failure state
        @state.delete("failed_creative_id")
        @state.delete("failure_reason")

        @parent_task.update!(
          status: "running",
          workflow_state: @state
        )

        post_notice(
          I18n.t("collavre.comments.work_command.workflow_resumed",
                 agent: @parent_task.agent.display_name,
                 remaining: pending.size)
        )

        advance!
      end

      private

      def skip_current!
        pending = @state["pending_creative_ids"] || []
        pending.shift
        @state["pending_creative_ids"] = pending
        @parent_task.update!(workflow_state: @state)
      end

      def complete_workflow!
        @parent_task.update!(status: "done")
        @parent_task.creative&.update!(progress: 1.0)

        post_notice(
          I18n.t("collavre.comments.work_command.workflow_completed",
                 agent: @parent_task.agent.display_name,
                 completed: (@state["completed_creative_ids"] || []).size)
        )
      end

      def post_progress_notice(creative)
        total = @state["total"] || 1
        completed_count = (@state["completed_creative_ids"] || []).size
        current_index = completed_count + 1
        creative_desc = creative.description&.truncate(50) || "untitled"

        post_notice(
          I18n.t("collavre.comments.work_command.subtask_started",
                 agent: @parent_task.agent.display_name,
                 creative: creative_desc,
                 current: current_index,
                 total: total)
        )
      end

      def post_subtask_completed_notice(sub_task, completed_count, total)
        creative_desc = sub_task.creative&.description&.truncate(50) || "untitled"
        progress_pct = ((completed_count.to_f / total) * 100).round

        post_notice(
          I18n.t("collavre.comments.work_command.subtask_completed",
                 agent: @parent_task.agent.display_name,
                 creative: creative_desc,
                 completed: completed_count,
                 total: total,
                 progress: progress_pct)
        )
      end

      def post_failure_notice(sub_task, error_message)
        creative_desc = sub_task.creative&.description&.truncate(50) || "unknown"
        post_notice(
          I18n.t("collavre.comments.work_command.workflow_failed",
                 agent: @parent_task.agent.display_name,
                 creative: creative_desc,
                 reason: error_message || "unknown error")
        )
      end

      def post_notice(content)
        post_workflow_notice(@parent_task, content)
      end

      def build_subtask_context(creative)
        original_user = find_original_user

        # Build rich trigger comment with creative content + workflow instruction
        # This mimics a user manually asking the agent in the creative's chat
        trigger_content = build_trigger_content(creative)

        trigger_comment = creative.comments.create!(
          content: trigger_content,
          user: original_user,
          topic_id: nil
        )

        # Context matches the format MessageBuilder expects:
        # - creative.id → MessageBuilder renders creative tree markdown + chat history
        # - comment.id → points to trigger comment in the child creative
        # - sender → original user who issued /work
        {
          "creative" => { "id" => creative.id, "description" => creative.description },
          "workflow" => {
            "context" => @parent_task.workflow_context,
            "parent_task_id" => @parent_task.id
          },
          "comment" => { "id" => trigger_comment.id, "content" => trigger_comment.content,
                         "user_id" => trigger_comment.user_id },
          "sender" => { "name" => original_user.name, "id" => original_user.id }
        }
      end

      def build_trigger_content(_creative)
        # Resolve workflow_context: if it's a creative ID, render that creative's markdown
        # as the instruction (like a user pasting the content). Otherwise use as-is.
        # NOTE: Do NOT prefix with @Agent — the trigger comment is authored by the
        # original /work user, not the agent. Including @Agent causes the agent to
        # interpret it as a self-referencing instruction.
        # MessageBuilder already renders current creative's markdown from context["creative"]["id"].
        content = resolve_workflow_context

        # If a supervisor is assigned, append instruction to consult them instead of asking the user
        supervisor = @state["supervisor"]
        if supervisor
          supervisor_instruction = I18n.t(
            "collavre.comments.work_command.supervisor_instruction",
            supervisor: supervisor["name"]
          )
          content = "#{content}\n\n#{supervisor_instruction}"
        end

        content
      end

      def resolve_workflow_context
        resolve_workflow_context_from_task(@parent_task, @state)
      end

      def render_creative_markdown(creative)
        render_creative_markdown_for_task(@parent_task, creative)
      end

      def find_original_user
        find_original_user_from_task(@parent_task)
      end

      def refilter_pending(creative_ids)
        return [] if creative_ids.empty?
        creative_ids - filter_active_or_completed(creative_ids)
      end
    end
  end
end
