# frozen_string_literal: true

module Collavre
  class TriggerLoopCheckJob < ApplicationJob
    include TriggerLoopHelpers

    queue_as :default

    # Evaluates whether a trigger loop should continue after an AI agent
    # completes a task. Checks the agent's last response for [STATUS: ...]
    # tags to determine next action.
    #
    # Status flow:
    #   idle → running → completed | awaiting_user | stuck | max_reached
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
        handle_infra_error(child_creative, topic, parent_creative, loop_config, task)
        return
      end

      status = evaluate_status(last_agent_comment, loop_config)

      # LLM fallback: when agent doesn't use [STATUS: ...] tags, ask LLM
      # to determine whether the work is actually done.
      if status == :no_tag
        status = llm_fallback_evaluate(child_creative, parent_creative, last_agent_comment)
      end

      case status
      when :done
        # Transition to pending_verification and enqueue LLM verification
        update_loop_data(child_creative, state: "pending_verification", infra_retry_count: 0)
        TriggerLoopVerifyJob.perform_later(task.id)
      when :awaiting_user
        update_loop_data(child_creative, state: "awaiting_user", infra_retry_count: 0)
        post_system_notice(child_creative, topic, I18n.t(
          "collavre.trigger_loop.awaiting_user",
          iteration: loop_config["current_iteration"]
        ))
      when :continue
        iteration = (loop_config["current_iteration"] || 0) + 1
        max = loop_config["max_iterations"] || 10

        if iteration >= max
          update_loop_data(child_creative, state: "max_reached", infra_retry_count: 0)
          post_system_notice(child_creative, topic, I18n.t(
            "collavre.trigger_loop.max_reached",
            max: max
          ))
        else
          update_loop_data(child_creative,
            state: "running", current_iteration: iteration,
            last_task_id: task.id, infra_retry_count: 0)
          post_continue_instruction(child_creative, topic, parent_creative, iteration, max)
        end
      end
    end

    private

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
    def handle_infra_error(child_creative, topic, parent_creative, loop_config, task)
      max = loop_config["max_iterations"] || 10
      iteration = loop_config["current_iteration"] || 0
      infra_retries = (loop_config["infra_retry_count"] || 0) + 1

      if infra_retries >= MAX_INFRA_RETRIES
        update_loop_data(child_creative, state: "stuck", infra_retry_count: infra_retries)
        post_system_notice(child_creative, topic, I18n.t(
          "collavre.trigger_loop.infra_stuck",
          count: infra_retries
        ))
        return
      end

      update_loop_data(child_creative,
        state: "running", current_iteration: iteration,
        last_task_id: task.id, infra_retry_count: infra_retries)

      post_retry_instruction(child_creative, topic, parent_creative, iteration, max)
    end

    def evaluate_status(comment, loop_config)
      content = comment.content.to_s

      # Parse structured [STATUS: ...] tag — DONE requires explicit tag
      if content.match?(/\[STATUS:\s*DONE\b/i)
        return :done
      end

      if content.match?(/\[STATUS:\s*BLOCKED\b/i)
        return :awaiting_user
      end

      if content.match?(/\[STATUS:\s*CONTINUE\b/i)
        return :continue
      end

      # Keyword fallback — only for blocked detection, NOT for completion.
      stuck = loop_config["stuck_conditions"] || []
      if stuck.any? { |kw| content.downcase.include?(kw.downcase) }
        return :awaiting_user
      end

      # No status tag found — signal for LLM fallback evaluation
      :no_tag
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

    def find_trigger_agent(creative)
      creative.all_shared_users(:write)
              .map(&:user)
              .find(&:ai_user?)
    end

    # LLM fallback: when the agent doesn't use [STATUS: ...] tags,
    # ask an LLM to evaluate whether the work described in the response
    # indicates completion, continuation, or a blocked state.
    LLM_FALLBACK_SYSTEM_PROMPT = <<~PROMPT.freeze
      You are a task status evaluator. Given the original task instructions and an AI agent's response, determine the task's current status.

      Rules:
      - DONE: The agent has executed all required actions (created PRs, moved items, updated records, etc.) — not merely described or planned them.
      - CONTINUE: The agent made progress but explicitly mentions remaining work it intends to do.
      - BLOCKED: The agent cannot proceed without external help (missing permissions, unclear requirements, dependency on others).

      Respond with exactly one word: DONE, CONTINUE, or BLOCKED.
    PROMPT

    def llm_fallback_evaluate(child_creative, parent_creative, agent_comment)
      verifier = pick_fallback_agent(parent_creative)

      unless verifier
        # No AI agent available for fallback — default to continue
        return :continue
      end

      instructions = collect_fallback_instructions(child_creative, parent_creative)

      prompt = <<~PROMPT
        ## Task instructions:
        #{instructions}

        ## Agent's response:
        #{agent_comment.content.to_s.truncate(3000)}

        ## Question:
        Based on the agent's response, is the task DONE, should it CONTINUE, or is it BLOCKED?
        Respond with exactly one word: DONE, CONTINUE, or BLOCKED.
      PROMPT

      client = AiClient.new(
        vendor: verifier.llm_vendor,
        model: verifier.llm_model,
        system_prompt: LLM_FALLBACK_SYSTEM_PROMPT,
        llm_api_key: verifier.llm_api_key || verifier.creator&.llm_api_key,
        gateway_url: verifier.gateway_url.presence || verifier.creator&.gateway_url,
        context: {}
      )

      response_text = +""
      client.chat([ { role: "user", text: prompt } ]) do |delta|
        response_text << delta
      end

      cleaned = response_text.strip.upcase
      case cleaned
      when /\ADONE\b/
        :done
      when /\ABLOCKED\b/
        :awaiting_user
      else
        :continue
      end
    rescue StandardError => e
      Rails.logger.error("[TriggerLoopCheckJob] LLM fallback failed: #{e.class} #{e.message}")
      # On LLM failure, default to continue to avoid false completion
      :continue
    end

    # Pick an AI agent for fallback evaluation — prefer feedback+ agents,
    # fall back to the trigger agent itself.
    def pick_fallback_agent(creative)
      ai_agents = creative.all_shared_users(:feedback)
                          .map(&:user)
                          .select(&:ai_user?)

      return ai_agents.first if ai_agents.any?

      # Fall back to write-permission agents (the trigger agent)
      creative.all_shared_users(:write)
              .map(&:user)
              .find(&:ai_user?)
    end

    # Collect instructions from context creatives for LLM evaluation
    def collect_fallback_instructions(child_creative, parent_creative)
      parts = []
      seen_ids = Set.new

      parent_creative.context_creatives.each do |ctx|
        next if seen_ids.include?(ctx.id)
        seen_ids.add(ctx.id)
        desc = ctx.description.to_s.strip
        parts << desc if desc.present?
      end

      child_creative.context_creatives.each do |ctx|
        next if seen_ids.include?(ctx.id)
        seen_ids.add(ctx.id)
        desc = ctx.description.to_s.strip
        parts << desc if desc.present?
      end

      child_desc = child_creative.description.to_s.strip
      parts << "Task: #{child_desc}" if child_desc.present?

      parts.join("\n\n---\n\n")
    end
  end
end
