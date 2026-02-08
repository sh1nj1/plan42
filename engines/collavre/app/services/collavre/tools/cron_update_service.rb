module Collavre
require "sorbet-runtime"
require "rails_mcp_engine"
module Tools
  class CronUpdateService
    extend T::Sig
    extend ToolMeta

    tool_name "cron_update"
    tool_description "Update the schedule, message, or description of an existing recurring job. Only jobs for creatives you have write access to can be updated."

    tool_param :key, description: "The unique key of the cron job to update.", required: true
    tool_param :schedule, description: "New cron schedule expression (optional).", required: false
    tool_param :message, description: "New message content (optional).", required: false
    tool_param :description, description: "New description (optional).", required: false

    sig do
      params(
        key: String,
        schedule: T.nilable(String),
        message: T.nilable(String),
        description: T.nilable(String)
      ).returns(T::Hash[Symbol, T.untyped])
    end
    def call(key:, schedule: nil, message: nil, description: nil)
      raise "Current.user is required" unless Current.user

      task = SolidQueue::RecurringTask.find_by(key: key, static: false)
      return { error: "Cron job not found", key: key } unless task

      args = parse_arguments(task)
      creative_id = args["creative_id"] || parse_creative_id_from_key(key)
      creative = Creative.find_by(id: creative_id)

      unless creative&.has_permission?(Current.user, :write)
        return { error: "No write permission to update this cron job", key: key }
      end

      if schedule.present?
        parsed = Fugit.parse(schedule)
        unless parsed.is_a?(Fugit::Cron)
          return { error: "Invalid cron schedule: #{schedule}. Use cron syntax like '0 9 * * *'." }
        end
        task.schedule = schedule
      end

      if message.present?
        new_args = args.merge("message" => message)
        task.arguments = [ new_args.symbolize_keys ]
      end

      task.description = description if description.present?

      unless task.save
        return { error: "Failed to update cron job", details: task.errors.full_messages }
      end

      {
        success: true,
        key: task.key,
        schedule: task.schedule,
        description: task.description,
        next_run: task.next_time&.iso8601
      }
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
