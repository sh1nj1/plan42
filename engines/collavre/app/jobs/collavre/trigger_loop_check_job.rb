# frozen_string_literal: true

module Collavre
  class TriggerLoopCheckJob < ApplicationJob
    queue_as :default

    # Evaluates whether a trigger loop should continue after an AI agent
    # completes a task. Checks the agent's last response for [STATUS: ...]
    # tags to determine next action.
    #
    # Status flow:
    #   idle → running → completed | stuck | max_reached
    def perform(task_id)
      task = Task.find_by(id: task_id)
      return unless task&.creative

      child_creative = task.creative
      parent_creative = child_creative.parent
      return unless parent_creative&.drop_trigger_enabled?

      # Loop state is stored on the child creative (each child has its own loop)
      loop_config = child_creative.data&.dig("trigger", "loop")
      return unless loop_config && loop_config["state"] == "running"

      # Use the task's topic directly — not a stored topic_id which can become stale
      topic = Topic.find_by(id: task.topic_id)
      return unless topic

      # Only evaluate tasks from the loop's trigger topic to prevent
      # cross-topic contamination from unrelated AI conversations
      trigger_topic_id = loop_config["trigger_topic_id"]
      return if trigger_topic_id.present? && trigger_topic_id != task.topic_id

      last_agent_comment = find_last_agent_comment(child_creative, topic, task)
      return unless last_agent_comment

      # Infrastructure errors (timeout, connection failure) → retry without consuming iteration
      if infrastructure_error?(last_agent_comment)
        retry_without_iteration(child_creative, topic, parent_creative, loop_config, task)
        return
      end

      # Agent actually responded (not infra error) — reset infra retry count
      reset_infra_retry_count(child_creative)

      status = evaluate_status(last_agent_comment, loop_config)

      case status
      when :done
        update_loop_state(child_creative, "completed")
      when :stuck
        update_loop_state(child_creative, "stuck")
        post_system_notice(child_creative, topic, I18n.t(
          "collavre.trigger_loop.stuck",
          iteration: loop_config["current_iteration"]
        ))
      when :continue
        iteration = (loop_config["current_iteration"] || 0) + 1
        max = loop_config["max_iterations"] || 10

        if iteration >= max
          update_loop_state(child_creative, "max_reached")
          post_system_notice(child_creative, topic, I18n.t(
            "collavre.trigger_loop.max_reached",
            max: max
          ))
        else
          update_loop_iteration(child_creative, iteration, task.id)
          post_continue_instruction(child_creative, topic, parent_creative, iteration, max)
        end
      end
    end

    private

    def find_last_agent_comment(creative, topic, task)
      # Bind to this task's agent to avoid reading unrelated AI comments
      # that may appear during cooldown delay
      creative.comments
              .where(topic_id: topic.id, user_id: task.agent_id)
              .where("comments.created_at >= ?", task.created_at)
              .order(created_at: :desc)
              .first
    end

    # Detect infrastructure errors (timeout, connection failure, etc.)
    # These are NOT valid task results — the agent never actually worked.
    MAX_INFRA_RETRIES = 3

    INFRASTRUCTURE_ERROR_PATTERNS = [
      /OpenClaw Error/i,
      /(?:request|connection|server)\s+timed?\s*out/i,
      /connection\s*(refused|reset|closed)/i,
      /internal\s*server\s*error/i,
      /\b50[234]\b.*(?:error|gateway|unavailable)/i
    ].freeze

    def infrastructure_error?(comment)
      content = comment.content.to_s
      INFRASTRUCTURE_ERROR_PATTERNS.any? { |pattern| content.match?(pattern) }
    end

    # Retry without consuming an iteration — the agent never actually worked.
    # Safety net: after MAX_INFRA_RETRIES consecutive infra errors, transition to stuck.
    def retry_without_iteration(child_creative, topic, parent_creative, loop_config, task)
      max = loop_config["max_iterations"] || 10
      iteration = loop_config["current_iteration"] || 0
      infra_retries = (loop_config["infra_retry_count"] || 0) + 1

      if infra_retries >= MAX_INFRA_RETRIES
        update_loop_state(child_creative, "stuck")
        update_infra_retry_count(child_creative, infra_retries)
        post_system_notice(child_creative, topic, I18n.t(
          "collavre.trigger_loop.infra_stuck",
          count: infra_retries
        ))
        return
      end

      update_loop_iteration(child_creative, iteration, task.id)
      update_infra_retry_count(child_creative, infra_retries)

      post_retry_instruction(child_creative, topic, parent_creative, iteration, max)
    end

    def evaluate_status(comment, loop_config)
      content = comment.content.to_s

      # Parse structured [STATUS: ...] tag — DONE requires explicit tag
      if content.match?(/\[STATUS:\s*DONE\b/i)
        return :done
      end

      if content.match?(/\[STATUS:\s*BLOCKED\b/i)
        return :stuck
      end

      if content.match?(/\[STATUS:\s*CONTINUE\b/i)
        return :continue
      end

      # Keyword fallback — only for stuck detection, NOT for completion.
      # Completion requires explicit [STATUS: DONE] to prevent false positives.
      stuck = loop_config["stuck_conditions"] || []
      if stuck.any? { |kw| content.downcase.include?(kw.downcase) }
        return :stuck
      end

      # Default: continue (agent didn't report DONE, so work is incomplete)
      :continue
    end

    def update_loop_state(child_creative, new_state)
      data = child_creative.data || {}
      trigger = data["trigger"] || {}
      loop_data = trigger["loop"] || {}
      loop_data["state"] = new_state
      trigger["loop"] = loop_data
      data["trigger"] = trigger
      child_creative.update!(data: data)
    end

    def update_infra_retry_count(child_creative, count)
      data = child_creative.data || {}
      trigger = data["trigger"] || {}
      loop_data = trigger["loop"] || {}
      loop_data["infra_retry_count"] = count
      trigger["loop"] = loop_data
      data["trigger"] = trigger
      child_creative.update!(data: data)
    end

    def reset_infra_retry_count(child_creative)
      loop_data = child_creative.data&.dig("trigger", "loop")
      return unless loop_data&.key?("infra_retry_count") && loop_data["infra_retry_count"].to_i > 0

      update_infra_retry_count(child_creative, 0)
    end

    def update_loop_iteration(child_creative, iteration, task_id)
      data = child_creative.data || {}
      trigger = data["trigger"] || {}
      loop_data = trigger["loop"] || {}
      loop_data["current_iteration"] = iteration
      loop_data["last_task_id"] = task_id
      loop_data["state"] = "running"
      trigger["loop"] = loop_data
      data["trigger"] = trigger
      child_creative.update!(data: data)
    end

    def post_continue_instruction(child_creative, topic, parent_creative, iteration, max)
      agent = find_trigger_agent(parent_creative)
      return unless agent

      content = "@#{agent.name}: #{I18n.t(
        'collavre.trigger_loop.continue',
        iteration: iteration,
        max: max
      )}"

      child_creative.comments.create!(
        content: content,
        topic_id: topic.id,
        private: false,
        user: child_creative.user,
        skip_dispatch: false  # Let after_create_commit dispatch this
      )
    end

    def post_retry_instruction(child_creative, topic, parent_creative, iteration, max)
      agent = find_trigger_agent(parent_creative)
      return unless agent

      content = "@#{agent.name}: #{I18n.t(
        'collavre.trigger_loop.retry',
        iteration: iteration,
        max: max
      )}"

      child_creative.comments.create!(
        content: content,
        topic_id: topic.id,
        private: false,
        user: child_creative.user,
        skip_dispatch: false
      )
    end

    def post_system_notice(creative, topic, content)
      creative.comments.create!(
        content: content,
        topic_id: topic.id,
        private: false,
        skip_default_user: true
      )
    end

    def find_trigger_agent(creative)
      creative.all_shared_users(:write)
              .map(&:user)
              .find(&:ai_user?)
    end
  end
end
