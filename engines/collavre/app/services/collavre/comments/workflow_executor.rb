module Collavre
  module Comments
    class WorkflowExecutor
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

        completed << sub_task.creative_id
        pending.delete(sub_task.creative_id)

        @state["completed_creative_ids"] = completed
        @state["pending_creative_ids"] = pending
        @state["current_creative_id"] = nil
        @parent_task.update!(workflow_state: @state)

        total = @state["total"] || 1
        progress = completed.size.to_f / total
        @parent_task.creative&.update!(progress: progress.clamp(0.0, 1.0))

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
        comment_id = @parent_task.trigger_event_payload&.dig("comment", "id")
        return unless comment_id

        original_comment = Comment.find_by(id: comment_id)
        return unless original_comment

        original_comment.creative.comments.create!(
          content: content,
          user: @parent_task.agent,
          topic_id: original_comment.topic_id
        )
      end

      def build_subtask_context(creative)
        original_user = find_original_user
        trigger_comment = creative.comments.create!(
          content: I18n.t("collavre.comments.work_command.trigger_comment",
                         context: @parent_task.workflow_context),
          user: original_user,
          topic_id: nil
        )

        {
          "creative" => { "id" => creative.id, "description" => creative.description },
          "workflow" => {
            "context" => @parent_task.workflow_context,
            "parent_task_id" => @parent_task.id,
            "instruction" => "You are working on this creative as part of a workflow. " \
                           "The workflow context is: #{@parent_task.workflow_context}. " \
                           "Focus on this specific creative: #{creative.description}. " \
                           "When done, your work will be marked complete automatically."
          },
          "comment" => { "id" => trigger_comment.id, "content" => trigger_comment.content,
                         "user_id" => trigger_comment.user_id },
          "chat" => {
            "content" => "#{@parent_task.workflow_context}\n\nCurrent creative: #{creative.description}"
          }
        }
      end

      def find_original_user
        comment_id = @parent_task.trigger_event_payload&.dig("comment", "id")
        comment = Comment.find_by(id: comment_id) if comment_id
        comment&.user || @parent_task.agent
      end

      def refilter_pending(creative_ids)
        return [] if creative_ids.empty?

        # Remove creatives that now have completed tasks or full progress
        tasked = Task.where(creative_id: creative_ids)
                     .where(status: %w[running queued pending pending_approval done])
                     .pluck(:creative_id)

        completed = Creative.where(id: creative_ids)
                            .where("progress >= 1.0")
                            .pluck(:id)

        skip_ids = (tasked + completed).uniq
        creative_ids - skip_ids
      end
    end
  end
end
