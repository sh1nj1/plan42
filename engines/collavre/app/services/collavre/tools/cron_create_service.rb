module Collavre
require "sorbet-runtime"
require "rails_mcp_engine"
module Tools
  class CronCreateService
    extend T::Sig
    extend ToolMeta

    tool_name "cron_create"
    tool_description "Create a new recurring scheduled job. The job will periodically post a message to a creative's topic, creating the named topic when it does not exist, and triggering agent orchestration. Schedule uses cron syntax (e.g., '*/5 * * * *' for every 5 minutes, '0 9 * * *' for daily at 9am)."

    tool_param :creative_id, description: "The creative ID to post recurring messages to.", required: true
    tool_param :topic_name, description: "The topic name within the creative to post to. Missing topics are created automatically. Use 'Main' for the default main topic.", required: true
    tool_param :schedule, description: "Cron schedule expression (e.g., '0 9 * * *' for daily at 9am, '*/30 * * * *' for every 30 minutes).", required: true
    tool_param :message, description: "The message content to post on each execution. This triggers the agent orchestration pipeline.", required: true
    tool_param :description, description: "Human-readable description of what this cron job does.", required: false

    sig do
      params(
        creative_id: Integer,
        topic_name: String,
        schedule: String,
        message: String,
        description: T.nilable(String)
      ).returns(T::Hash[Symbol, T.untyped])
    end
    def call(creative_id:, topic_name:, schedule:, message:, description: nil)
      raise "Current.user is required" unless Current.user

      creative = Creative.find_by(id: creative_id)
      return { error: "Creative not found", id: creative_id } unless creative
      unless creative.has_permission?(Current.user, :write)
        return { error: "No write permission on this Creative", id: creative_id }
      end

      unless Fugit.parse(schedule).is_a?(Fugit::Cron)
        return { error: "Invalid cron schedule: #{schedule}. Use cron syntax like '0 9 * * *'." }
      end

      topic, topic_created = resolve_topic(creative, topic_name)
      return topic if topic.is_a?(Hash) && topic[:error]

      key = "cron_#{creative_id}_#{SecureRandom.hex(4)}"

      task = create_task(
        topic: topic, creative: creative, creative_id: creative_id, topic_created: topic_created,
        key: key, schedule: schedule, message: message, description: description
      )
      return task if task.is_a?(Hash) && task[:error]

      topic_created ? broadcast_topic_created(topic) : Crons::ChangeBroadcaster.call(creative)

      {
        success: true,
        key: task.key,
        schedule: task.schedule,
        description: task.description,
        creative_id: creative_id,
        topic_name: topic_name,
        next_run: task.next_time&.iso8601
      }
    end

    private

    def create_task(topic:, creative:, creative_id:, key:, schedule:, message:, description:, topic_created:)
      creation_error = nil
      retained_created_topic = false
      task = topic.with_lock do
        return { error: I18n.t("collavre.creative_history.read_only") } if topic.history?
        unless topic.creative_id == creative.effective_origin.id
          return { error: I18n.t("collavre.comments.invalid_topic") }
        end

        persist_task(
          topic: topic, creative_id: creative_id, key: key, schedule: schedule,
          message: message, description: description
        )
      rescue StandardError => e
        retained_created_topic = clean_up_failed_topic_creation(topic) if topic_created
        creation_error = e
        nil
      end
      broadcast_topic_created(topic) if retained_created_topic
      raise creation_error if creation_error

      task
    end

    def clean_up_failed_topic_creation(topic)
      return true if recurring_topic_adopted?(topic)

      topic.destroy!
      false
    end

    def recurring_topic_adopted?(topic)
      Crons::RecurringTopicTasks.new(topic.id).any?
    rescue StandardError => e
      Rails.logger.warn("[CronCreateService] Failed to check topic #{topic.id} adoption: #{e.message}")
      false
    end

    def persist_task(topic:, creative_id:, key:, schedule:, message:, description:)
      SolidQueue::RecurringTask.create!(
        key: key,
        class_name: "Collavre::CronActionJob",
        schedule: schedule,
        queue_name: "default",
        static: false,
        description: description || "Cron job for creative #{creative_id}",
        arguments: [ {
          creative_id: creative_id,
          topic_id: topic.id,
          agent_id: Current.user.id,
          message: message
        } ]
      )
    end

    def resolve_topic(creative, topic_name)
      origin = creative.effective_origin
      if topic_name.casecmp(Creative::MAIN_TOPIC_NAME).zero?
        return [ origin.main_topic(fallback_user: Current.user), false ]
      end

      topic = origin.topics.find_by(name: topic_name)
      return [ { error: I18n.t("collavre.creative_history.read_only") }, false ] if topic&.history?
      return [ topic, false ] if topic
      return [ { error: I18n.t("collavre.topics.reserved_name") }, false ] if Topics::ReservedName.reserved?(origin, topic_name)

      topic = origin.topics.find_or_create_by!(name: topic_name) { |created| created.user = Current.user }
      [ topic, topic.previously_new_record? ]
    end

    def broadcast_topic_created(topic)
      TopicsChannel.broadcast_to(
        topic.creative,
        { action: "created", topic: topic.slice(:id, :name), user_id: Current.user.id, cron_changed: true }
      )
    rescue StandardError => e
      Rails.logger.warn("[CronCreateService] Failed to broadcast created topic #{topic.id}: #{e.message}")
    end
  end
end
end
