# frozen_string_literal: true

require "sorbet-runtime"
require "rails_mcp_engine"

module Collavre
  module Tools
    class TaskStatusService
      extend T::Sig
      extend ToolMeta

      tool_name "task_status"
      tool_description "Check an instruction by comment_id or explicit task_ids (exactly one). Includes descendants via event causation, checking read permissions for every task. not_started means no task exists yet; it does not prove dispatch will occur. needs_attention takes priority over in_progress. cancelled is reported separately. done only means all agent turns ended successfully; inspect replies to judge the requested outcome. Returns at most 200 tasks; larger chains raise an error."
      tool_param :comment_id, description: "Instruction comment id returned by topic_message_create.", required: false
      tool_param :task_ids, description: "Task ids, comma-separated or an array (maximum 100).", required: false

      sig do
        params(comment_id: T.nilable(Integer), task_ids: T.nilable(T.any(String, Integer, T::Array[T.untyped])))
          .returns(T::Hash[Symbol, T.untyped])
      end
      def call(comment_id: nil, task_ids: nil)
        user = TaskTracking.user!
        TaskTracking.invalid!(:choose_input) unless comment_id.present? ^ task_ids.present?
        roots = comment_id ? for_comment(comment_id, user) : for_ids(task_ids)
        tasks = TaskDescendants.collect(roots)
        tasks.each { |task| TaskTracking.authorize!(task, user) }
        { comment_id: comment_id, status: aggregate(tasks),
          tasks: TaskTracking.describe_all(tasks, user) }
      end

      private

      def for_comment(id, user)
        comment = TaskTracking.visible_comments(user).find(id)
        TopicAuthorizer.authorize_creative!(comment.creative, :read, user: user)
        Task.where(trigger_comment_id: id).includes(:agent).limit(TaskDescendants::MAX_TASKS + 1).to_a.tap do |tasks|
          TaskTracking.invalid!(:too_many_tasks) if tasks.size > TaskDescendants::MAX_TASKS
        end
      end

      def for_ids(value)
        ids = IdList.parse(value)
        TaskTracking.invalid!(:invalid_ids) unless ids.size.between?(1, 100)
        tasks = Task.where(id: ids).includes(:agent).to_a
        raise ActiveRecord::RecordNotFound unless tasks.size == ids.size

        tasks
      end

      def aggregate(tasks)
        return "not_started" if tasks.empty?
        return "needs_attention" if tasks.any? { |task| task.status.in?(%w[failed escalated pending_approval]) }
        return "in_progress" if tasks.any?(&:active?)
        return "cancelled" if tasks.any?(&:cancelled?)

        "done"
      end
    end
  end
end
