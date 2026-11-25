# frozen_string_literal: true

require "sorbet-runtime"
require "rails_mcp_engine"

module Collavre
  module Tools
    class TopicTasksService
      extend T::Sig
      extend ToolMeta

      tool_name "topic_tasks"
      tool_description "List tasks in a readable topic, newest first. Active uses the same statuses as Stop. Finished includes unsuccessful endings. Reply summaries respect private-message visibility. A done task means a turn ended, not that the requested outcome was verified."
      tool_param :topic_id, description: "Topic to inspect."
      tool_param :status, description: "active (default), finished, or all.", required: false
      tool_param :limit, description: "Maximum tasks, 1 to 100 (default 20).", required: false

      sig { params(topic_id: Integer, status: String, limit: Integer).returns(T::Hash[Symbol, T.untyped]) }
      def call(topic_id:, status: "active", limit: 20)
        user = TaskTracking.user!
        TaskTracking.invalid!(:invalid_status) unless %w[active finished all].include?(status)
        TaskTracking.invalid!(:invalid_limit) unless (1..100).cover?(limit)
        topic = Topic.find(topic_id)
        TopicAuthorizer.authorize_read!(topic, user: user)
        scope = Task.where(topic_id: topic.id, creative_id: topic.creative_id).includes(:agent)
        scope = filter(scope, status)
        tasks = TaskTracking.visible_tasks(scope, user, creative_id: topic.creative_id).order(created_at: :desc, id: :desc).limit(limit + 1).to_a
        { topic_id: topic.id, tasks: TaskTracking.describe_all(tasks.first(limit), user),
          has_more: tasks.size > limit }
      end

      private

      def filter(scope, status)
        return scope.where(status: Task::ACTIVE_STATUSES) if status == "active"
        return scope.where.not(status: Task::ACTIVE_STATUSES) if status == "finished"

        scope
      end
    end
  end
end
