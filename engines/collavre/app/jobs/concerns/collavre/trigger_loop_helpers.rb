# frozen_string_literal: true

module Collavre
  module TriggerLoopHelpers
    extend ActiveSupport::Concern

    private

    def decision_agent(creative, task_agent_id = nil)
      native = creative.find_ai_agent(:feedback, capability: :judge, excluding: task_agent_id)
      native ||= creative.find_ai_agent(:feedback, capability: :judge)
      return native if native

      agents = creative.all_shared_users(:feedback).map(&:user).compact.select { |agent| agent.supports?(:chat) }
      agents.find { |agent| agent.id != task_agent_id } || agents.first
    end

    def decision_client(verifier, task, system_prompt)
      AiClient.new(
        vendor: verifier.llm_vendor, model: verifier.llm_model, system_prompt: system_prompt,
        llm_api_key: verifier.llm_api_key.presence || verifier.creator&.llm_api_key,
        gateway_url: verifier.gateway_url.presence || verifier.creator&.gateway_url,
        context: { user: verifier, usage_source_task: task, creative: task.creative, topic_id: task.topic_id }
      )
    end

    # Resolve the task's current topic while excluding unrelated conversations.
    def trigger_completion_topic(task, loop_config)
      id = loop_config["trigger_topic_id"]
      return if id.present? && id != task.topic_id

      Topic.find_by(id: task.topic_id)
    end

    # Abandonment has no agent result to evaluate, and its card may be gone.
    def finish_abandoned_replay(task, creative, topic)
      return false unless task.trigger_event_payload&.dig("engine_login", "replay_abandoned")
      # Only a turn that can complete this loop supersedes abandonment.
      return true if newer_loop_completion_task?(task, creative, topic)

      update_loop_data(creative, state: "awaiting_user", infra_retry_count: 0)
      notice_topic = topic.creative_id == creative.id ? topic : creative.main_topic
      post_system_notice(creative, notice_topic, I18n.t("collavre.inline_agent_login.replay_abandoned"))
      true
    end

    def newer_loop_completion_task?(task, creative, topic)
      Task.where(creative_id: creative.id, topic_id: topic.id, trigger_event_name: "comment_created")
          .where(status: Task::ACTIVE_STATUSES + [ "done" ])
          .where("created_at > :time OR (created_at = :time AND id > :id)", time: task.created_at, id: task.id)
          .any? do |newer|
        newer.active? || (!newer.unsuccessful_loop_response? && !newer.trigger_event_payload&.dig("engine_login", "replay_abandoned"))
      end
    end

    # Find the last comment by the task's agent in the trigger topic,
    # scoped to comments created after the task was dispatched.
    def find_last_agent_comment(creative, topic, task)
      creative.comments
              .where(topic_id: topic.id, user_id: task.agent_id)
              .where("comments.created_at >= ?", task.created_at)
              .order(created_at: :desc)
              .first
    end

    # Single method to update loop state — avoids multiple DB writes per Job execution.
    # Only the keys passed in `changes` are updated; others are preserved.
    def update_loop_data(child_creative, **changes)
      child_creative.with_lock do
        data = child_creative.data || {}
        trigger = data["trigger"] || {}
        loop_data = trigger["loop"] || {}
        changes.each { |key, value| loop_data[key.to_s] = value }
        trigger["loop"] = loop_data
        data["trigger"] = trigger
        child_creative.update!(data: data)
      end
    end

    # Post a system notice (no specific user author) in the trigger topic.
    def post_system_notice(creative, topic, content)
      creative.comments.create!(
        content: content,
        topic_id: topic.id,
        private: false,
        skip_default_user: true
      )
    end
  end
end
