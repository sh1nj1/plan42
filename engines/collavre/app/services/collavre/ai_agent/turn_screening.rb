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
