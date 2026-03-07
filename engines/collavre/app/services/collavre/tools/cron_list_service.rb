module Collavre
require "sorbet-runtime"
require "rails_mcp_engine"
module Tools
  class CronListService
    extend T::Sig
    extend ToolMeta

    tool_name "cron_list"
    tool_description "List recurring scheduled jobs. Returns all cron jobs for creatives the current user has access to. Filter by creative_id to see jobs for a specific creative."

    tool_param :creative_id, description: "Filter by creative ID. If omitted, lists all accessible cron jobs.", required: false

    sig { params(creative_id: T.nilable(Integer)).returns(T::Hash[Symbol, T.untyped]) }
    def call(creative_id: nil)
      raise "Current.user is required" unless Current.user

      tasks = SolidQueue::RecurringTask.where(static: false)

      if creative_id.present?
        creative = Creative.find_by(id: creative_id)
        return { error: "Creative not found", id: creative_id } unless creative
        unless creative.has_permission?(Current.user, :read)
          return { error: "No read permission on this Creative", id: creative_id }
        end
        tasks = tasks.where("key LIKE ?", "cron_#{creative_id.to_i}_%")
      end

      results = tasks.filter_map do |task|
        args = parse_arguments(task)
        task_creative_id = args["creative_id"] || parse_creative_id_from_key(task.key)
        task_creative = Creative.find_by(id: task_creative_id)
        next unless task_creative&.has_permission?(Current.user, :read)

        {
          key: task.key,
          schedule: task.schedule,
          description: task.description,
          creative_id: task_creative_id,
          topic_id: args["topic_id"],
          agent_id: args["agent_id"],
          message: args["message"],
          created_at: task.created_at&.iso8601
        }
      end

      { success: true, cron_jobs: results, count: results.size }
    end

    private

    def parse_arguments(task)
      args = task.arguments
      return {} unless args.is_a?(Array) && args.first.is_a?(Hash)

      args.first.stringify_keys
    end

    def parse_creative_id_from_key(key)
      match = key.match(/\Acron_(\d+)_/)
      match[1].to_i if match
    end
  end
end
end
