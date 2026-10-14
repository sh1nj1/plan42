# frozen_string_literal: true

module Collavre
  class TriggerLoopVerifyJob < ApplicationJob
    include TriggerLoopHelpers

    queue_as :default

    # Verifies whether an agent's [STATUS: DONE] claim is genuine by asking
    # a separate LLM to compare the agent's response against the original
    # instructions. If the verification fails, the loop continues instead
    # of completing.
    #
    # The verifier agent is chosen from feedback+ permission AI agents on
    # the creative, preferring one that is NOT the original task agent.
    # Falls back to the task agent if no alternative exists.
    def perform(task_id)
      task = Task.find_by(id: task_id)
      return unless task&.creative

      child_creative = task.creative
      parent_creative = child_creative.parent
      return unless parent_creative&.drop_trigger_enabled?

      loop_config = child_creative.data&.dig("trigger", "loop")
      return unless loop_config && loop_config["state"] == "pending_verification"

      topic = Topic.find_by(id: task.topic_id)
      return unless topic

      # Only verify tasks from the loop's trigger topic (cross-topic guard)
      trigger_topic_id = loop_config["trigger_topic_id"]
      return if trigger_topic_id.present? && trigger_topic_id != task.topic_id

      last_agent_comment = find_last_agent_comment(child_creative, topic, task)
      return unless last_agent_comment

      instructions = collect_instructions(child_creative, parent_creative)
      verifier = pick_verifier_agent(child_creative, task.agent_id)

      unless verifier
        # No verifier available — accept DONE as-is
        update_loop_data(child_creative, state: "completed")
        return
      end

      result = verify_completion(verifier, instructions, last_agent_comment.content.to_s, task)

      if result == :verified
        update_loop_data(child_creative, state: "completed")
      elsif result == :awaiting_user
        # Agent correctly paused to wait for user — do NOT re-loop
        update_loop_data(child_creative, state: "awaiting_user")
        post_system_notice(child_creative, topic, I18n.t(
          "collavre.trigger_loop.awaiting_user",
          iteration: loop_config["current_iteration"]
        ))
      else
        # Verification failed — continue the loop
        iteration = (loop_config["current_iteration"] || 0) + 1
        max = loop_config["max_iterations"] || 10

        if iteration >= max
          update_loop_data(child_creative, state: "max_reached")
          post_system_notice(child_creative, topic, I18n.t(
            "collavre.trigger_loop.max_reached", max: max
          ))
        else
          update_loop_data(child_creative,
            state: "running", current_iteration: iteration,
            last_task_id: task.id)
          post_verification_failed(child_creative, topic, task.agent, iteration, max, result)
        end
      end
    end

    private

    # Collect instructions from context creatives of both parent and child
    def collect_instructions(child_creative, parent_creative)
      parts = []
      seen_ids = Set.new

      # Parent's context creatives (trigger instructions, dev rules, etc.)
      parent_creative.context_creatives.each do |ctx|
        next if seen_ids.include?(ctx.id)
        seen_ids.add(ctx.id)
        desc = ctx.description.to_s.strip
        parts << desc if desc.present?
      end

      # Child's own context creatives (may have additional instructions)
      child_creative.context_creatives.each do |ctx|
        next if seen_ids.include?(ctx.id)
        seen_ids.add(ctx.id)
        desc = ctx.description.to_s.strip
        parts << desc if desc.present?
      end

      # Child's own description (the task itself)
      child_desc = child_creative.description.to_s.strip
      parts << "Task: #{child_desc}" if child_desc.present?

      parts.join("\n\n---\n\n")
    end

    # Pick a verifier AI agent: prefer one with feedback+ permission that
    # is NOT the original task agent. Fall back to the task agent only if
    # no other AI agent exists.
    def pick_verifier_agent(creative, task_agent_id)
      decision_agent(creative, task_agent_id)
    end

    VERIFY_SYSTEM_PROMPT = <<~PROMPT.freeze
      You are a strict task completion verifier. Your job is to determine whether an AI agent has ACTUALLY completed all required actions described in the instructions.

      Rules:
      - Compare the agent's response against every action item in the instructions.
      - "Completed" means the agent EXECUTED the action (e.g. created a PR, moved a creative, updated a record), not merely described or planned it.
      - If the agent says something "needs to be done" or "should be done" but didn't do it, that is NOT completed.
      - Be strict: if ANY required action was not executed, respond INCOMPLETE.
      - IMPORTANT: If the agent correctly identified that it needs user approval, user input, or user action before it can proceed, and has paused/stopped to wait for the user, respond AWAITING_USER. This is NOT incomplete work — the agent did the right thing by asking.
    PROMPT

    def verify_completion(verifier, instructions, agent_response, task)
      prompt = <<~PROMPT
        ## Instructions given to the agent:
        #{instructions}

        ## Agent's response:
        #{agent_response}

        ## Question:
        Did the agent actually execute ALL required actions in the instructions?
        Respond with exactly one of:
        - VERIFIED — all actions were executed
        - AWAITING_USER — the agent correctly paused to wait for user approval/input/action
        - INCOMPLETE: [list the unexecuted actions]
      PROMPT

      result = decision_client(verifier, task, VERIFY_SYSTEM_PROMPT).judge(prompt, questions: {
        status: { type: :choice, instructions: "Were all required actions actually executed?",
                  options: { VERIFIED: "All actions executed", AWAITING_USER: "Correctly waiting for human action",
                             INCOMPLETE: "Required actions remain" } }
      })
      case result.dig("answers", "status", "choice")
      when "VERIFIED" then :verified
      when "AWAITING_USER" then :awaiting_user
      else
        incomplete_reason(result, prompt, task)
      end
    rescue StandardError => e
      Rails.logger.error("[TriggerLoopVerifyJob] LLM verification failed: #{e.class} #{e.message}")
      I18n.t("collavre.trigger_loop.verification_error")
    end

    def incomplete_reason(result, prompt, task)
      return result["reason"] if result["reason"].present?

      agent = task.creative.find_ai_agent(:feedback, capability: :chat)
      if result["source"] == "judge" && agent
        explanation = decision_client(agent, task, VERIFY_SYSTEM_PROMPT).chat([
          { role: "user", text: "#{prompt}\nThe decision is INCOMPLETE. List only the unexecuted actions as a short explanation." }
        ])
      end
      explanation.presence || I18n.t("collavre.trigger_loop.incomplete_reason")
    rescue StandardError
      I18n.t("collavre.trigger_loop.incomplete_reason")
    end

    def post_verification_failed(child_creative, topic, task_agent, iteration, max, reason)
      return unless task_agent

      content = "@#{task_agent.name}: #{I18n.t(
        'collavre.trigger_loop.verification_failed',
        iteration: iteration,
        max: max,
        reason: reason.to_s.truncate(500)
      )}"

      child_creative.comments.create!(
        content: content,
        topic_id: topic.id,
        private: false,
        user: child_creative.user,
        skip_dispatch: false
      )
    end
  end
end
