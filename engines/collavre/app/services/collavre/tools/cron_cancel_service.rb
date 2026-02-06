module Collavre
require "sorbet-runtime"
require "rails_mcp_engine"
module Tools
  class CronCancelService
    extend T::Sig
    extend ToolMeta

    tool_name "cron_cancel"
    tool_description "Cancel (delete) a recurring scheduled job by its key. Only jobs for creatives you have write access to can be cancelled."

    tool_param :key, description: "The unique key of the cron job to cancel (from cron_list).", required: true

    sig { params(key: String).returns(T::Hash[Symbol, T.untyped]) }
    def call(key:)
      raise "Current.user is required" unless Current.user

      task = SolidQueue::RecurringTask.find_by(key: key, static: false)
      return { error: "Cron job not found", key: key } unless task

      args = parse_arguments(task)
      creative_id = args["creative_id"] || parse_creative_id_from_key(key)
      creative = Creative.find_by(id: creative_id)

      unless creative&.has_permission?(Current.user, :write)
        return { error: "No write permission to cancel this cron job", key: key }
      end

      task.destroy!

      { success: true, key: key, message: "Cron job cancelled successfully" }
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
