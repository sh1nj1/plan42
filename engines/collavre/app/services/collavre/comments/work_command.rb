module Collavre
  module Comments
    class WorkCommand
      include Concerns::WorkflowSupport

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
        worker, supervisor = find_agents
        return I18n.t("collavre.comments.work_command.agent_not_found") unless worker
        return I18n.t("collavre.comments.work_command.no_children") if creative.descendants.empty?

        workflow_text = extract_workflow_context
        child_ids = collect_dfs_creative_ids
        skipped_ids = filter_already_tasked(child_ids)
        pending_ids = child_ids - skipped_ids

        return I18n.t("collavre.comments.work_command.all_already_tasked") if pending_ids.empty?

        parent_task = create_parent_task(worker, supervisor, workflow_text, pending_ids)
        WorkflowExecutor.advance!(parent_task)

        I18n.t("collavre.comments.work_command.started",
               agent: worker.display_name,
               total: pending_ids.size,
               skipped: skipped_ids.size)
      end

      # Parse mentioned AI agents: first = worker, second = supervisor (optional)
      # Usage: /work @Worker @Supervisor: context
      def find_agents
        mentioned = MentionParser.resolve_all_users(comment.content.to_s).select(&:ai_user?)
        worker = mentioned.first
        supervisor = mentioned.second # nil if only one agent mentioned
        [ worker, supervisor ]
      end

      def extract_workflow_context
        content = comment.content.to_s.strip
        content = content.sub(/\A\/work\s+/, "")
        # Strip @mentions using the same pattern as MentionParser
        content = content.gsub(MentionParser::MENTION_PATTERN, "")
        content.strip
      end

      def collect_dfs_creative_ids
        dfs_ids = []
        dfs_traverse(creative) { |c| dfs_ids << c.id }
        dfs_ids.reject { |id| id == creative.id }
      end

      def filter_already_tasked(creative_ids)
        filter_active_or_completed(creative_ids)
      end

      def create_parent_task(worker, supervisor, workflow_text, pending_ids)
        state = {
          "pending_creative_ids" => pending_ids,
          "completed_creative_ids" => [],
          "current_creative_id" => nil,
          "total" => pending_ids.size
        }

        # Store supervisor info for WorkflowExecutor to include in trigger comments
        if supervisor
          state["supervisor"] = { "id" => supervisor.id, "name" => supervisor.display_name }
        end

        Task.create!(
          name: "Workflow: #{creative.description&.truncate(50)}",
          status: "running",
          agent: worker,
          creative: creative,
          workflow_context: workflow_text,
          workflow_state: state,
          trigger_event_name: "work_command",
          trigger_event_payload: {
            "creative" => { "id" => creative.id },
            "comment" => { "id" => comment.id, "user_id" => comment.user_id }
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
