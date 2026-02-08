module Collavre
require "sorbet-runtime"
require "rails_mcp_engine"
module Tools
  class CronCreateService
    extend T::Sig
    extend ToolMeta

    tool_name "cron_create"
    tool_description "Create a new recurring scheduled job. The job will periodically post a message to a creative's topic, triggering agent orchestration. Schedule uses cron syntax (e.g., '*/5 * * * *' for every 5 minutes, '0 9 * * *' for daily at 9am)."

    tool_param :creative_id, description: "The creative ID to post recurring messages to.", required: true
    tool_param :topic_id, description: "The topic ID within the creative to post to.", required: true
    tool_param :schedule, description: "Cron schedule expression (e.g., '0 9 * * *' for daily at 9am, '*/30 * * * *' for every 30 minutes).", required: true
    tool_param :message, description: "The message content to post on each execution. This triggers the agent orchestration pipeline.", required: true
    tool_param :description, description: "Human-readable description of what this cron job does.", required: false

    sig do
      params(
        creative_id: Integer,
        topic_id: Integer,
        schedule: String,
        message: String,
        description: T.nilable(String)
      ).returns(T::Hash[Symbol, T.untyped])
    end
    def call(creative_id:, topic_id:, schedule:, message:, description: nil)
      raise "Current.user is required" unless Current.user

      creative = Creative.find_by(id: creative_id)
      return { error: "Creative not found", id: creative_id } unless creative
      unless creative.has_permission?(Current.user, :write)
        return { error: "No write permission on this Creative", id: creative_id }
      end

      topic = Topic.find_by(id: topic_id, creative_id: creative.effective_origin.id)
      return { error: "Topic not found or does not belong to this creative", topic_id: topic_id } unless topic

      parsed = Fugit.parse(schedule)
      unless parsed.is_a?(Fugit::Cron)
        return { error: "Invalid cron schedule: #{schedule}. Use cron syntax like '0 9 * * *'." }
      end

      suffix = SecureRandom.hex(4)
      key = "cron_#{creative_id}_#{suffix}"

      task = SolidQueue::RecurringTask.create!(
        key: key,
        class_name: "Collavre::CronActionJob",
        schedule: schedule,
        queue_name: "default",
        static: false,
        description: description || "Cron job for creative #{creative_id}",
        arguments: [ {
          creative_id: creative_id,
          topic_id: topic_id,
          agent_id: Current.user.id,
          message: message
        } ]
      )

      {
        success: true,
        key: task.key,
        schedule: task.schedule,
        description: task.description,
        creative_id: creative_id,
        next_run: task.next_time&.iso8601
      }
    end
  end
end
end
