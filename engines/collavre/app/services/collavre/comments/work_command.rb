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
        subcommand = parse_subcommand
        case subcommand
        when :stop then execute_stop
        when :resume then execute_resume
        else execute_start
        end
      end

      def parse_subcommand
        content = comment.content.to_s.strip.sub(/\A\/work\s*/i, "")
        case content
        when /\Astop\b/i then :stop
        when /\Aresume\b/i then :resume
        else :start
        end
      end

      # --- /work stop ---

      def execute_stop
        parent_task = find_active_workflow
        return I18n.t("collavre.comments.work_command.no_active_workflow") unless parent_task

        WorkflowExecutor.new(parent_task).stop!
        I18n.t("collavre.comments.work_command.stopped",
               agent: parent_task.agent.display_name)
      end

      # --- /work resume ---

      def execute_resume
        parent_task = find_resumable_workflow
        return I18n.t("collavre.comments.work_command.no_resumable_workflow") unless parent_task

        WorkflowExecutor.new(parent_task).resume!
        parent_task.reload
        I18n.t("collavre.comments.work_command.resumed",
               agent: parent_task.agent.display_name,
               remaining: (parent_task.workflow_state["pending_creative_ids"] || []).size)
      end

      # --- /work start (default) ---

      def execute_start
        agent = find_agent
        return I18n.t("collavre.comments.work_command.agent_not_found") unless agent
        return I18n.t("collavre.comments.work_command.no_children") if creative.descendants.empty?

        workflow_text = extract_workflow_context
        child_ids = collect_dfs_creative_ids
        skipped_ids = filter_already_tasked(child_ids)
        pending_ids = child_ids - skipped_ids

        return I18n.t("collavre.comments.work_command.all_already_tasked") if pending_ids.empty?

        parent_task = create_parent_task(agent, workflow_text, pending_ids)
        WorkflowExecutor.advance!(parent_task)

        I18n.t("collavre.comments.work_command.started",
               agent: agent.display_name,
               total: pending_ids.size,
               skipped: skipped_ids.size)
      end

      def find_agent
        mentioned = MentionParser.resolve_all_users(comment.content.to_s)
        mentioned.find(&:ai_user?)
      end

      def extract_workflow_context
        content = comment.content.to_s.strip
        content = content.sub(/\A\/work\s+/, "")
        content = content.sub(/@[^:]+:\s*/, "")
        content.strip
      end

      def collect_dfs_creative_ids
        dfs_ids = []
        dfs_traverse(creative) { |c| dfs_ids << c.id }
        dfs_ids.reject { |id| id == creative.id }
      end

      def dfs_traverse(node, &block)
        yield node
        node.children.order(:sequence).each { |child| dfs_traverse(child, &block) }
      end

      def filter_already_tasked(creative_ids)
        tasked = Task.where(creative_id: creative_ids)
                     .where(status: %w[running queued pending pending_approval done])
                     .pluck(:creative_id)

        completed = Creative.where(id: creative_ids)
                            .where("progress >= 1.0")
                            .pluck(:id)

        (tasked + completed).uniq
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

      def find_active_workflow
        Task.where(creative: creative, trigger_event_name: "work_command", status: "running")
            .order(created_at: :desc).first
      end

      def find_resumable_workflow
        Task.where(creative: creative, trigger_event_name: "work_command", status: %w[failed cancelled])
            .order(created_at: :desc).first
      end
    end
  end
end
