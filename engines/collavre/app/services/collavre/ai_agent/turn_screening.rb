# frozen_string_literal: true

module Collavre
  module AiAgent
    # Prompt-injection screening of the turn AiAgentService is about to hand
    # its agent (Screening::TurnGuard), and delivery of a Claude Channel turn
    # as it was screened. See docs/prompt_injection_screening.md.
    module TurnScreening
      # AiAgentJob calls this before it marks a Claude Channel turn delegated,
      # while the task is still running and can pause for approval. The
      # screened text is what #call delivers.
      def screen_channel_turn!
        generation = Orchestration::ExecutionFence.generation(@task)
        @creative = find_creative
        content = ClaudeChannelAdapter.trigger_content(@context, @agent)
        2.times do
          screening_guard.call([ { source: "trigger", text: content } ])
          # Comments can leave this creative or topic while the screener runs.
          refreshed_content = Comment.uncached { ClaudeChannelAdapter.trigger_content(@context, @agent) }
          return @screened_channel_content = content if refreshed_content == content

          content = refreshed_content
        end

        @task.with_lock do
          @task.update!(status: "cancelled") if @task.running? &&
            !Orchestration::ExecutionFence.superseded?(@task, generation)
        end
        raise CancelledError
      rescue ApprovalPendingError => e
        handle_approval_pending(e)
      end

      private

      def check_screening_authorization!
        return unless Screening.enabled? && @creative
        return if Creatives::PermissionChecker.current_tree_allowed?(@creative.id, @agent, :feedback)

        @task.cancel_if_active!
        raise CancelledError
      end

      # Adapters receive newly resolved messages and do not replay RubyLLM snapshots.
      def restoring_approval_snapshot?
        AiClient::VENDOR_TO_PROVIDER.key?(@agent.llm_vendor.to_s.downcase) &&
          ApprovalConversation.restoring_snapshot?(@task.pending_tool_call)
      end

      def screen_llm_turn!(resolved)
        if restoring_approval_snapshot?
          @screening_flagged = restore_screening_flag!(@task.pending_tool_call)
        else
          messages = resolved[:messages]
          texts = Screening.texts_for(messages, owner_id: @agent.created_by_id)
          screening_guard(messages).call(texts, unverified_context: unverified_creative_context?(messages))
          @screening_flagged = false
        end
      end

      def restore_screening_flag!(pending)
        reason_flagged = screen_gate_reason(pending) == "flagged"
        return false unless Screening.flagged?(@task) || reason_flagged

        screening_guard.apply_flag(!server_gated_tools?) == "flagged"
      end

      # Rendered creative context and document quotes can include other
      # authors' text. A session filter can drop the context but keep the quote.
      def unverified_creative_context?(messages)
        messages.any? { |message| message[:kind].in?(%i[creative_context context_creative referenced_creative]) } ||
          (@original_comment&.creative_quote? && messages.any? { |message| message[:kind] == :trigger })
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

      def screening_guard(messages = [])
        Screening::TurnGuard.new(task: @task, agent: @agent, creative: @creative,
                                 context: @context, principal: workspace_user, authors: screening_authors(messages))
      end

      # Who wrote the comments this turn carries: the anchor, the comments
      # folded into it, a workflow's source message and retained chat history.
      def screening_authors(messages)
        ids = [ @context.dig("comment", "id"), *Array(@context["merged_comment_ids"]),
                Workflow::SourceMessage.comment_id(@context, @agent) ].compact
        history_ids = messages.filter_map { |message| message[:author_id] if message[:kind] == :chat_history }
        User.where(id: Comment.where(id: ids).pluck(:user_id) | history_ids).to_a
      end
    end
  end
end
