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
      task = loop_task(task_id)
      return unless task

      child_creative = task.creative
      parent_creative = child_creative.trigger_loop_context
      return unless child_creative.trigger_loop_enabled?

      # Loop state is stored on the child creative (each child has its own loop)
      loop_config = child_creative.data&.dig("trigger", "loop")
      return unless loop_config && loop_config["state"] == "running"

      topic = trigger_completion_topic(task, loop_config)
      return unless topic
      return if finish_abandoned_replay(task, child_creative, topic)

      last_agent_comment = find_last_agent_comment(child_creative, topic, task)
      return unless last_agent_comment

      # The provider rejected the prompt as too large → retrying sends the same
      # prompt and fails the same way, so pause instead of looping on it.
      if prompt_too_large_error?(last_agent_comment)
        update_loop_data(child_creative, state: "stuck", infra_retry_count: 0)
        post_loop_notice(child_creative, topic, I18n.t("collavre.trigger_loop.prompt_too_large"))
        return
      end

      # Infrastructure errors (timeout, connection failure) → retry without consuming iteration
      if infrastructure_error?(last_agent_comment)
        handle_infra_error(child_creative, topic, parent_creative, loop_config, task)
        return
      end

      status = evaluate_response(child_creative, parent_creative, last_agent_comment, task, loop_config)

      case status
      when :done
        # Transition to pending_verification and enqueue LLM verification
        enqueue_verification(child_creative, task)
      when :awaiting_user
        update_loop_data(child_creative, state: "awaiting_user", infra_retry_count: 0)
        post_loop_notice(child_creative, topic, I18n.t(
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
    rescue TriggerLoopHelpers::StaleLoopError
      nil
    end

    private

    # An approval continuation now owns a handed-off turn; its stale BLOCKED reply must not pause the loop.
    def loop_task(task_id)
      task = Task.find_by(id: task_id)
      return unless task&.creative
      return if task.trigger_event_payload&.dig(KeepLoop::CONTINUED_KEY)

      @loop_task_id = task.id
      task
    end

    # Recheck under the creative lock: the approval handoff may land after perform's early return.
    def validate_loop_snapshot!(loop_data, creative)
      super
      raise StaleLoopError if Task.where(id: @loop_task_id).pick(:trigger_event_payload)&.dig(KeepLoop::CONTINUED_KEY)
    end

    def enqueue_verification(creative, task)
      update_loop_data(creative, state: "pending_verification", infra_retry_count: 0)
      raise ActiveJob::EnqueueError, "Verification enqueue rejected" if TriggerLoopVerifyJob.perform_later(task.id) == false
    rescue StandardError
      restore_retryable_loop_turn(creative)
      raise
    end

    # Detect infrastructure errors (timeout, connection failure, etc.)
    # These are NOT valid task results — the agent never actually worked.
    MAX_INFRA_RETRIES = 3

    # Generic, vendor-neutral infrastructure-error signatures. Vendor engines
    # register their own provider-specific signatures (e.g. an OpenClaw gateway
    # error banner) via register_infrastructure_error_pattern, so core names no
    # vendor here.
    BUILTIN_INFRASTRUCTURE_ERROR_PATTERNS = [
      /(?:request|connection|server)\s+timed?\s*out/i,
      /connection\s*(refused|reset|closed)/i,
      /internal\s*server\s*error/i,
      /\b50[234]\b.*(?:error|gateway|unavailable)/i
    ].freeze

    class << self
      def registered_infrastructure_error_patterns
        @registered_infrastructure_error_patterns ||= []
      end

      def register_infrastructure_error_pattern(pattern)
        registered_infrastructure_error_patterns << pattern unless registered_infrastructure_error_patterns.include?(pattern)
      end

      def infrastructure_error_patterns
        BUILTIN_INFRASTRUCTURE_ERROR_PATTERNS + registered_infrastructure_error_patterns
      end
    end

    # Provider rejections of an oversized prompt, as AiClient#chat streams
    # them into the reply ("⚠️ AI Error: ..."). Matched only on that error
    # line so an agent merely discussing context limits does not stop a loop.
    PROMPT_TOO_LARGE_PATTERNS = [
      /input_too_large/i,
      /context_length_exceeded/i,
      /maximum context length/i,
      /prompt is too long/i,
      /input token count exceeds/i,
      /exceeds the maximum (?:input )?length/i
    ].freeze

    def prompt_too_large_error?(comment)
      error_line = comment.content.to_s[/⚠️ AI Error:.*/]
      error_line.present? && PROMPT_TOO_LARGE_PATTERNS.any? { |pattern| error_line.match?(pattern) }
    end

    def infrastructure_error?(comment)
      content = comment.content.to_s
      self.class.infrastructure_error_patterns.any? { |pattern| content.match?(pattern) }
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

    def evaluate_response(creative, context, comment, task, config)
      status = evaluate_status(comment, config)
      status == :no_tag ? llm_fallback_evaluate(creative, context, comment, task) : status
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
      agent = continuation_agent(child_creative, topic)
      return if !agent && !child_creative.keep_loop?

      content = "#{"@#{agent.name}: " if agent}#{I18n.t(
        'collavre.trigger_loop.continue',
        iteration: iteration,
        max: max
      )}"

      post_loop_instruction(child_creative,
        content: content,
        topic_id: topic.id,
        private: false,
        user: child_creative.user
      )
    end

    def post_retry_instruction(child_creative, topic, parent_creative, iteration, max)
      agent = continuation_agent(child_creative, topic)
      return if !agent && !child_creative.keep_loop?

      content = "#{"@#{agent.name}: " if agent}#{I18n.t(
        'collavre.trigger_loop.retry',
        iteration: iteration,
        max: max
      )}"

      post_loop_instruction(child_creative,
        content: content,
        topic_id: topic.id,
        private: false,
        user: child_creative.user
      )
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

    PROMPT

    def llm_fallback_evaluate(child_creative, parent_creative, agent_comment, task)
      verifier = pick_fallback_agent(parent_creative, child_creative, task&.agent_id)

      unless verifier && Creatives::PermissionChecker.current_allowed?(child_creative.id, verifier, :feedback)
        # No AI agent available for fallback — default to continue
        return :continue
      end

      instructions = collect_fallback_instructions(child_creative, parent_creative, verifier)

      prompt = <<~PROMPT
        ## Task instructions:
        #{instructions}

        ## Agent's response:
        #{agent_comment.content.to_s.truncate(3000)}

        ## Question:
        Based on the agent's response, is the task DONE, should it CONTINUE, or is it BLOCKED?
      PROMPT

      result = decision_client(verifier, task, LLM_FALLBACK_SYSTEM_PROMPT).judge(prompt, questions: {
        status: { type: :choice, instructions: "Determine the current task status.",
                  options: { DONE: "All required actions executed", CONTINUE: "Work remains", BLOCKED: "External help needed" } }
      })
      case result.dig("answers", "status", "choice")
      when "DONE" then :done
      when "BLOCKED" then :awaiting_user
      else :continue
      end
    rescue StandardError => e
      Rails.logger.error("[TriggerLoopCheckJob] LLM fallback failed: #{e.class} #{e.message}")
      # On LLM failure, default to continue to avoid false completion
      :continue
    end

    # Pick an AI agent for fallback evaluation — prefer feedback+ agents,
    # fall back to the trigger agent itself.
    def pick_fallback_agent(_creative, child_creative, task_agent_id = nil)
      ai_agents = child_creative.all_shared_users(:feedback)
                          .map(&:user)
                          .select { |agent| (agent.supports?(:judge) || agent.supports?(:chat)) && Creatives::PermissionChecker.current_allowed?(child_creative.id, agent, :feedback) }

      return decision_agent(ai_agents) if ai_agents.any?

      # Prefer task write agents before the independently authorized keep task agent.
      task_agent = User.find_by(id: task_agent_id) if child_creative.keep_loop?
      (child_creative.all_shared_users(:write).map(&:user) + [ task_agent ]).compact.uniq(&:id)
              .find { |agent| (agent.supports?(:judge) || agent.supports?(:chat)) && Creatives::PermissionChecker.current_allowed?(child_creative.id, agent, :feedback) }
    end

    # Collect instructions from context creatives for LLM evaluation
    def collect_fallback_instructions(child_creative, parent_creative, verifier)
      parts = [ child_creative.data&.dig("trigger", "loop", "goal") ].compact
      contexts = (parent_creative.context_creatives.to_a + child_creative.context_creatives.to_a).uniq(&:id)
      contexts.each do |ctx|
        next unless Creatives::PermissionChecker.current_allowed?(ctx.id, verifier, :read)

        desc = ctx.description.to_s.strip
        parts << desc if desc.present?
      end

      child_desc = child_creative.description.to_s.strip
      parts << "Task: #{child_desc}" if child_desc.present?

      parts.join("\n\n---\n\n")
    end
  end
end
