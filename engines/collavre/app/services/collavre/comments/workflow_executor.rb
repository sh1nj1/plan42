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
        # Loop instead of recursion to avoid stack overflow on many missing creatives
        loop do
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

          # Update state
          @state["current_creative_id"] = next_creative_id
          @parent_task.update!(workflow_state: @state)

          # Create sub-task and dispatch to agent
          sub_task_context = build_subtask_context(next_creative)
          topic = next_creative.topics.first

          sub_task = Task.create!(
            name: "Work on: #{next_creative.description&.truncate(50)}",
            status: "pending",
            agent: @parent_task.agent,
            creative: next_creative,
            parent_task: @parent_task,
            workflow_context: @parent_task.workflow_context,
            trigger_event_name: "workflow_subtask",
            trigger_event_payload: sub_task_context,
            topic_id: topic&.id
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

        # Update parent creative progress
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
        topic = creative.topics.first
        {
          "creative" => { "id" => creative.id, "description" => creative.description },
          "topic" => topic ? { "id" => topic.id } : nil,
          "workflow" => {
            "context" => @parent_task.workflow_context,
            "parent_task_id" => @parent_task.id,
            "instruction" => "You are working on this creative as part of a workflow. " \
                           "The workflow context is: #{@parent_task.workflow_context}. " \
                           "Focus on this specific creative: #{creative.description}. " \
                           "When done, your work will be marked complete automatically."
          },
          "comment" => @parent_task.trigger_event_payload&.dig("comment"),
          "chat" => {
            "content" => "#{@parent_task.workflow_context}\n\nCurrent creative: #{creative.description}"
          }
        }.compact
      end
    end
  end
end
