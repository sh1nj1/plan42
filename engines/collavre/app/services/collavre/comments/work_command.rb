module Collavre
  module Comments
    class WorkCommand
      def initialize(comment:, user:)
        @comment = comment
        @user = user
        @creative = comment.creative.effective_origin
      end

      def call
        return unless work_command?
        execute_work
      rescue StandardError => e
        Rails.logger.error("Work command failed: #{e.message}")
        e.message
      end

      private

      COMMAND_PATTERN = /\A\/work\b/i.freeze

      attr_reader :comment, :user, :creative

      def work_command?
        comment.content.to_s.strip.match?(COMMAND_PATTERN)
      end

      def execute_work
        agent = find_agent
        return I18n.t("collavre.comments.work_command.agent_not_found") unless agent
        return I18n.t("collavre.comments.work_command.no_children") if creative.descendants.empty?

        workflow_text = extract_workflow_context
        child_ids = collect_dfs_creative_ids
        skipped_ids = filter_already_tasked(child_ids)
        pending_ids = child_ids - skipped_ids

        return I18n.t("collavre.comments.work_command.all_already_tasked") if pending_ids.empty?

        parent_task = create_parent_task(agent, workflow_text, pending_ids)
        start_next_subtask(parent_task, agent)

        I18n.t("collavre.comments.work_command.started",
               agent: agent.display_name,
               total: pending_ids.size,
               skipped: skipped_ids.size)
      end

      def find_agent
        comment.mentioned_users.find(&:ai_user?)
      end

      def extract_workflow_context
        # Remove command and @mention, rest is workflow context
        content = comment.content.to_s.strip
        content = content.sub(/\A\/work\s+/, "")
        content = content.sub(/@[^:]+:\s*/, "")
        content.strip
      end

      def collect_dfs_creative_ids
        # DFS order via closure_tree - children ordered by sequence
        dfs_ids = []
        dfs_traverse(creative) { |c| dfs_ids << c.id }
        dfs_ids.reject { |id| id == creative.id } # exclude root
      end

      def dfs_traverse(node, &block)
        yield node
        node.children.order(:sequence).each { |child| dfs_traverse(child, &block) }
      end

      def filter_already_tasked(creative_ids)
        Task.where(creative_id: creative_ids)
            .where(status: %w[running queued pending pending_approval])
            .pluck(:creative_id)
            .uniq
      end

      def create_parent_task(agent, workflow_text, pending_ids)
        Task.create!(
          name: "Workflow: #{creative.description&.truncate(50)}",
          status: "running",
          agent: agent,
          creative: creative,
          workflow_context: workflow_text,
          workflow_state: {
            "pending_creative_ids" => pending_ids,
            "completed_creative_ids" => [],
            "current_creative_id" => nil,
            "total" => pending_ids.size
          },
          trigger_event_name: "work_command",
          trigger_event_payload: {
            "creative" => { "id" => creative.id },
            "comment" => { "id" => comment.id }
          }
        )
      end

      def start_next_subtask(parent_task, agent)
        WorkflowExecutor.advance!(parent_task)
      end
    end
  end
end
