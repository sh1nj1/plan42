# frozen_string_literal: true

module Collavre
  module TriggerLoopHelpers
    extend ActiveSupport::Concern

    class StaleLoopError < StandardError; end

    private

    # Resolve the task's current topic while excluding unrelated conversations.
    def trigger_completion_topic(task, loop_config)
      @loop_original_data = loop_config.deep_dup
      @loop_start_comment_id = loop_config["start_comment_id"]
      @loop_expected_state = loop_config["state"]
      @loop_control_version = loop_config["control_version"]
      @loop_current_comment_id = loop_config["current_comment_id"]
      return unless task.creative.trigger_loop_task?(task)

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

    # Evaluate only the accepted task's reply, never another same-agent turn.
    def find_last_agent_comment(creative, topic, task)
      comment = creative.comments.find_by(task_id: task.id, topic_id: topic.id, user_id: task.agent_id)
      if !comment && creative.keep_loop? && task.done?
        update_loop_data(creative, state: "awaiting_user", infra_retry_count: 0)
      end
      comment
    end

    # Single method to update loop state — avoids multiple DB writes per Job execution.
    # Only the keys passed in `changes` are updated; others are preserved.
    def update_loop_data(child_creative, **changes)
      child_creative.with_lock do
        data = child_creative.data || {}
        trigger = data["trigger"] || {}
        loop_data = trigger["loop"] || {}
        validate_loop_snapshot!(loop_data)
        apply_loop_changes(loop_data, changes)
        trigger["loop"] = loop_data
        data["trigger"] = trigger
        child_creative.update!(data: data)
        @loop_expected_state = loop_data["state"] if defined?(@loop_expected_state)
      end
    end

    def validate_loop_snapshot!(loop_data)
      raise StaleLoopError if defined?(@loop_start_comment_id) && loop_data["start_comment_id"] != @loop_start_comment_id

      if defined?(@loop_expected_state)
        raise StaleLoopError unless loop_data["state"] == @loop_expected_state && loop_data["control_version"] == @loop_control_version
      end

      if defined?(@loop_current_comment_id) && loop_data["current_comment_id"] != @loop_current_comment_id
        raise StaleLoopError
      end
    end

    def apply_loop_changes(loop_data, changes)
      if loop_data.key?("current_comment_id") && changes[:state] == "running"
        changes[:current_comment_id] = nil
      end
      loop_data["control_version"] = loop_data.fetch("control_version", 0) + 1 if defined?(@loop_expected_state)
      @loop_control_version = loop_data["control_version"]
      changes.each { |key, value| loop_data[key.to_s] = value }
      @loop_current_comment_id = loop_data["current_comment_id"]
    end

    def post_loop_instruction(creative, **attributes)
      Comments::TopicMutation.call(attributes.fetch(:topic_id), creative.id) do
        creative.with_lock do
          validate_loop_snapshot!(creative.data&.dig("trigger", "loop") || {})
          comment = creative.comments.create!(**attributes, loop_continuation: true, skip_dispatch: true)
          agents = SystemEvents::Dispatcher.dispatch("comment_created", comment.dispatch_payload, source: "comment_callback")
          comment.send(:reconcile_loop_dispatch, agents)
        end
      end
    rescue StandardError
      restore_retryable_loop_turn(creative)
      raise
    end

    # Comment/task writes rolled back; restore the evaluator's accepted turn too.
    def restore_retryable_loop_turn(creative)
      return unless @loop_original_data

      creative.with_lock do
        config = creative.data&.dig("trigger", "loop") || {}
        validate_loop_snapshot!(config)
        restored = @loop_original_data.merge("control_version" => config.fetch("control_version", 0) + 1)
        data = creative.data.deep_dup
        data["trigger"]["loop"] = restored
        creative.update!(data: data)
      end
    rescue StaleLoopError
      nil
    end

    def continuation_agent(creative, topic)
      agent = creative.trigger_loop_agent
      if creative.keep_loop_agent_unavailable?
        update_loop_data(creative, state: "awaiting_user")
        post_system_notice(creative, topic, I18n.t("collavre.comments.keep_command.agent_not_authorized"))
        raise StaleLoopError
      end
      agent
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
