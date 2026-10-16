# frozen_string_literal: true

module Collavre
  module AiAgent
    # Prompt-injection screening of the turn AiAgentService is about to hand
    # its agent (Screening::TurnGuard), and delivery of a Claude Channel turn
    # as it was screened. See docs/prompt_injection_screening.md.
    module TurnScreening
      # AiAgentJob calls this before it marks a Claude Channel turn delegated,
      # while the task is still running and can pause for approval. The local
      # tools of a Claude Channel session are outside ApprovalGate, so a
      # flagged turn is not delivered at all. The screened text is what #call
      # delivers.
      def screen_channel_turn!
        @creative = find_creative
        content = ClaudeChannelAdapter.trigger_content(@context, @agent)
        result = screening_guard.call([ { source: "trigger", text: content } ], block_flagged: true)
        @screened_channel_content = content unless result == "skipped"
      rescue ApprovalPendingError => e
        handle_approval_pending(e)
      end

      private

      # Screens what this LLM turn hands the provider, after the session filter
      # and before anything is recorded as delivered. A flagged turn proceeds
      # only where every tool call passes through the server's approval gate
      # (AiClient#check_tool_approval!), and each call then waits for the agent
      # owner. Elsewhere (CLI Proxy, adapter vendors) it is blocked like a
      # Claude Channel turn. A turn resumed from an approval snapshot replays
      # what was screened, so it keeps its earlier flag.
      def screen_llm_turn!(resolved)
        pending = @task.pending_tool_call
        @screening_flagged =
          if ApprovalConversation.restoring_snapshot?(pending)
            Screening.flagged?(@task) || screen_gate_reason(pending) == "flagged"
          else
            texts = Screening.texts_for(resolved[:messages], owner_id: @agent.created_by_id)
            screening_guard.call(texts, block_flagged: !server_gated_tools?) == "flagged"
          end
      end

      # An approval_request decision is replayed to the model as its tool
      # result, reason included, and whoever decided wrote that reason.
      def screen_gate_reason(pending)
        decision = pending["kind"] == "approval_gate" && pending["decision"]
        reason = decision && decision["reason"].presence
        return "skipped" unless reason

        decider = User.find_by(id: decision["decided_by"])
        Screening::TurnGuard.new(task: @task, agent: @agent, creative: @creative, context: @context,
                                 principal: workspace_user, authors: [ decider ].compact)
                            .screen_followup([ { source: "approval_reason", text: reason } ], block_flagged: !server_gated_tools?)
      end

      # Every tool call can wait for the owner: the server runs the tools, and
      # the owner exists and can read the creative to decide.
      def server_gated_tools?
        vendor = @agent.llm_vendor.to_s.strip.downcase
        owner = @agent.creator
        AiClient::VENDOR_TO_PROVIDER.key?(vendor) && vendor != "cli_proxy" &&
          owner.present? && @creative&.has_permission?(owner, :read)
      end

      def delegate_to_claude_channel
        log_action("start", { message: "Delegating to Claude Channel via MCP" })

        ClaudeChannelAdapter.new(
          agent: @agent,
          context: @context,
          task: @task,
          **({ content: @screened_channel_content } if @screened_channel_content).to_h
        ).deliver

        # Drive the chat typing indicator for this async dispatch (and surface a
        # disconnect notice if no session is live). The dispatch above returns
        # immediately; ClaudeChannelPresenceJob keeps agent_status alive until the
        # reply lands or the session is gone — see the job for the full lifecycle.
        ClaudeChannelPresenceJob.perform_later(@task.id) if @task

        log_action("delegated", { message: "Message delivered to Claude Channel" })
        nil
      end

      def screening_guard
        Screening::TurnGuard.new(task: @task, agent: @agent, creative: @creative,
                                 context: @context, principal: workspace_user, authors: screening_authors)
      end

      # Who wrote the comments this turn carries: the anchor, the comments
      # folded into it and a workflow's source message.
      def screening_authors
        ids = [ @context.dig("comment", "id"), *Array(@context["merged_comment_ids"]),
                Workflow::SourceMessage.comment_id(@context, @agent) ].compact
        User.where(id: Comment.where(id: ids).select(:user_id)).to_a
      end
    end
  end
end
