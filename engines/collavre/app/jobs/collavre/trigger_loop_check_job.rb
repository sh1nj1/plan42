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

      topic = Topic.find_by(id: loop_config["topic_id"] || task.topic_id)
      return unless topic

      last_agent_comment = find_last_agent_comment(child_creative, topic, task)
      return unless last_agent_comment

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
      creative.comments
              .where(topic_id: topic.id)
              .joins(:user)
              .where.not(users: { llm_vendor: [ nil, "" ] })
              .where("comments.created_at >= ?", task.created_at)
              .order(created_at: :desc)
              .first
    end

    def evaluate_status(comment, loop_config)
      content = comment.content.to_s

      # Parse structured [STATUS: ...] tag
      if content.match?(/\[STATUS:\s*DONE\b/i)
        return :done
      end

      if content.match?(/\[STATUS:\s*BLOCKED\b/i)
        return :stuck
      end

      if content.match?(/\[STATUS:\s*CONTINUE\b/i)
        return :continue
      end

      # Fallback: check completion_conditions keywords
      conditions = loop_config["completion_conditions"] || []
      if conditions.any? { |kw| content.downcase.include?(kw.downcase) }
        return :done
      end

      # Fallback: check stuck_conditions keywords
      stuck = loop_config["stuck_conditions"] || []
      if stuck.any? { |kw| content.downcase.include?(kw.downcase) }
        return :stuck
      end

      # Default: continue
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
