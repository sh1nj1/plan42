module Collavre
  # Orchestrates AI agent execution for a task.
  # Delegates specific concerns to specialized service objects:
  # - AgentLifecycleManager: agent status, cancellation, heartbeats
  # - ResponseStreamer: streaming content updates
  # - ResponseFinalizer: comment finalization, review workflow
  # - A2aDispatcher: agent-to-agent event dispatch
  class AiAgentService
    # Compatibility alias for constants moved to AgentLifecycleManager
    CANCEL_CHECK_INTERVAL = AiAgent::AgentLifecycleManager::CANCEL_CHECK_INTERVAL

    def initialize(task)
      @task = task
      @agent = task.agent
      @context = task.trigger_event_payload
    end

    def call
      Current.set(user: @agent) do
        if @agent.claude_channel_agent?
          delegate_to_claude_channel
        else
          execute_llm_conversation
        end
      end
    rescue ApprovalPendingError => e
      summary = generate_approval_summary(e)
      AiAgent::ApprovalHandler.new(
        task: @task, agent: @agent, context: @context,
        creative: @creative, reply_comment: @reply_comment
      ).handle(e, summary: summary)
      raise
    rescue TurnDeadlineError => e
      handle_cancelled(
        action_type: "failed",
        message: "Turn exceeded the #{e.deadline_seconds}s deadline"
      )
      abort_agent_session_if_needed
      raise
    rescue CancelledError
      if @task.reload.status == "failed"
        handle_cancelled(action_type: "failed", message: "Task failed externally")
      else
        handle_cancelled
      end
      abort_agent_session_if_needed
      raise
    end

    private

    def delegate_to_claude_channel
      log_action("start", { message: "Delegating to Claude Channel via MCP" })

      AiAgent::ClaudeChannelAdapter.new(
        agent: @agent,
        context: @context,
        task: @task
      ).deliver

      # Drive the chat typing indicator for this async dispatch (and surface a
      # disconnect notice if no session is live). The dispatch above returns
      # immediately; ClaudeChannelPresenceJob keeps agent_status alive until the
      # reply lands or the session is gone — see the job for the full lifecycle.
      ClaudeChannelPresenceJob.perform_later(@task.id) if @task

      log_action("delegated", { message: "Message delivered to Claude Channel" })
      nil
    end

    def execute_llm_conversation
      log_action("start", { message: "Starting agent execution" })

      @original_comment = find_original_comment
      messages_data = build_messages
      log_action("prompt_generated", { messages: messages_data[:messages] })

      @creative = find_creative
      rendering_context = prepare_rendering_context
      system_prompt = render_system_prompt(rendering_context)

      resolved = resolve_session_context(messages_data, system_prompt)

      # Write down what this turn is about to hand the agent, before it hands it
      # over. A comment that landed after this task was dispatched and got swept
      # into the history window has been read by the agent, and the dispatch
      # still on its way for it should be dropped rather than queued behind this
      # turn. Recorded off `resolved` — after the session filter — because a
      # session-backed agent is sent only its :trigger and swallows nothing.
      Orchestration::DeliveryRecord.record!(@task, resolved)

      @reply_comment = create_reply_comment_if_needed

      @lifecycle_manager = AiAgent::AgentLifecycleManager.new(
        task: @task,
        agent: @agent,
        creative: @creative
      )

      @streamer = AiAgent::ResponseStreamer.new(
        reply_comment: @reply_comment,
        creative: @creative
      )

      @lifecycle_manager.broadcast_status("thinking")

      @client = build_ai_client(resolved[:system_prompt])
      begin
        stream_response(@client, resolved)
      ensure
        # Write down that the payload got there, whatever became of the turn
        # afterwards. In an `ensure` because the ending this is for leaves by
        # exception: a user pressing Stop mid-answer raises CancelledError out
        # of the block above, and the task ends `cancelled` — an undelivered
        # ending to every reader, although the agent has read this turn's
        # payload and every comment it swallowed. See
        # Orchestration::DeliveryRecord::HANDED_OFF_KEY.
        Orchestration::DeliveryRecord.mark_handed_off!(@task) if @client.handed_off?
      end

      # ...and write down when the handing over did not happen. The record
      # above licences discarding other dispatches on the strength of the agent
      # having read their comments; a request that never reached the provider
      # read nothing. AiAgentJob finishes this task `done` either way, so
      # without this the delivered ending is the one it ends in. See
      # Orchestration::DeliveryRecord::HANDOFF_FAILED_KEY.
      Orchestration::DeliveryRecord.mark_handoff_failed!(@task) if @client.last_handoff_failed?

      # Signal thinking state during finalize so the indicator shows ⏳
      @lifecycle_manager.broadcast_status("thinking")

      log_action("completion", { response: @streamer.content })

      finalized_comment = finalize_response
      # Stop/failure can land while the finalizer persists and broadcasts the
      # reply. Revalidate before dispatching that reply to other agents.
      @lifecycle_manager.check_cancelled!(force: true)
      dispatch_a2a(finalized_comment) unless @finalizer&.review_flow
      # A2A dispatch may itself perform I/O. Keep the normal return path from
      # handing a stale "success" to AiAgentJob after a terminal transition.
      @lifecycle_manager.check_cancelled!(force: true)

      @lifecycle_manager.broadcast_status("idle")

      @streamer.content
    end

    def find_original_comment
      target_comment_id = @context.dig("comment", "id")
      target_comment_id ? Comment.find_by(id: target_comment_id) : nil
    end

    def build_messages
      AiAgent::MessageBuilder.new(
        agent: @agent,
        context: @context,
        original_comment: @original_comment
      ).build
    end

    def resolve_session_context(messages_data, system_prompt)
      AiAgent::SessionContextResolver.new(
        agent: @agent,
        messages_data: messages_data,
        system_prompt: system_prompt
      ).resolve
    end

    def find_creative
      creative_id = @context.dig("creative", "id")
      creative_id ? Creative.find_by(id: creative_id) : nil
    end

    def prepare_rendering_context
      rendering_context = @context.dup
      if @creative
        rendering_context["creative"] = @creative.as_json
      end

      agent_context = build_agent_context(@creative)
      rendering_context.merge!(agent_context)
      rendering_context
    end

    def render_system_prompt(rendering_context)
      rendered = AiSystemPromptRenderer.new(
        template: @agent.system_prompt,
        context: rendering_context
      ).render

      collaboration_prompt = build_collaboration_prompt(@creative)
      if collaboration_prompt.present?
        "#{rendered}\n\n#{collaboration_prompt}"
      else
        rendered
      end
    end

    def create_reply_comment_if_needed
      return nil unless @original_comment

      @original_comment.creative.comments.create!(
        content: Comment::STREAMING_PLACEHOLDER_CONTENT,
        user: @agent,
        topic_id: @original_comment.topic_id,
        task: @task,
        skip_dispatch: true  # A2A routing handled by A2aDispatcher after finalization
      )
    end

    def build_ai_client(system_prompt)
      AiClient.new(
        vendor: @agent.llm_vendor,
        model: @agent.llm_model,
        system_prompt: system_prompt,
        llm_api_key: @agent.llm_api_key,
        gateway_url: @agent.gateway_url,
        context: {
          creative: @creative,
          user: @agent,
          task: @task,
          comment: @reply_comment || @original_comment
        },
        request_timeout_seconds: @lifecycle_manager.method(:remaining_deadline_seconds),
        # The streaming block below checks cancellation only when a text delta
        # arrives; a tool-only loop emits none, so the tool-call boundary is
        # that loop's only checkpoint against terminal status and the deadline.
        before_tool_call: ->(force = false) { @lifecycle_manager.check_cancelled!(force: force) }
      )
    end

    def stream_response(client, messages_data)
      # Prompt/session preparation can take long enough for Stop or
      # StuckDetector to end the task before the provider request begins.
      # Bypass the new manager's initial polling throttle at this handoff
      # boundary so a terminal turn cannot start remote tool side effects.
      @lifecycle_manager.check_cancelled!(force: true)
      response = client.chat(messages_data, tools: @agent.tools || []) do |delta|
        @lifecycle_manager.check_cancelled!
        @streamer.append(delta)
        @lifecycle_manager.heartbeat_if_needed
      end
      # A provider can return its final response inside the one-second polling
      # throttle after StuckDetector failed the task or the turn crossed its
      # deadline. This is the common completion boundary for RubyLLM and both
      # OpenClaw transports; validate it without throttling before finalization
      # can overwrite the terminal outcome.
      @lifecycle_manager.check_cancelled!(force: true)
      response
    end

    def finalize_response
      @finalizer = AiAgent::ResponseFinalizer.new(
        task: @task,
        agent: @agent,
        original_comment: @original_comment,
        reply_comment: @reply_comment,
        response_content: @streamer.content
      )
      @finalizer.finalize
    end

    def dispatch_a2a(finalized_comment)
      return unless finalized_comment

      dispatcher = AiAgent::A2aDispatcher.new(
        agent: @agent,
        reply_comment: finalized_comment,
        context: @context
      )
      dispatcher.dispatch
    end

    def handle_cancelled(action_type: "cancelled", message: "Task cancelled by user")
      @lifecycle_manager.handle_cancelled(
        reply_comment: @reply_comment,
        response_content: @streamer.content,
        action_type: action_type,
        message: message
      )

      # Reassociate activity logs if there was partial content
      if @reply_comment && @streamer.content_present?
        ActivityLog.where(comment: @original_comment, user: @agent)
                   .update_all(comment_id: @reply_comment.id)
      end
    end

    def log_action(type, payload, result = nil)
      @task.task_actions.create!(
        action_type: type,
        payload: payload,
        result: result,
        status: "done"
      )
    end

    def generate_approval_summary(error)
      return nil unless @client

      prompt = I18n.t(
        "collavre.ai_agent.approval.summary_prompt",
        tool_name: error.tool_name,
        arguments: error.tool_arguments.present? ? JSON.pretty_generate(error.tool_arguments) : "(none)"
      )

      @client.ask(prompt)
    end

    def build_agent_context(creative)
      return {} unless creative

      Orchestration::AgentContextBuilder.new(
        agent: @agent,
        creative: creative,
        sender: @context["sender"]
      ).build
    end

    def build_collaboration_prompt(creative)
      return nil unless creative

      Orchestration::AgentContextBuilder.new(
        agent: @agent,
        creative: creative,
        sender: @context["sender"],
        policy_resolver: build_policy_resolver
      ).to_collaboration_prompt
    end

    def build_policy_resolver
      Orchestration::PolicyResolver.new(@context)
    end

    def abort_agent_session_if_needed
      Collavre::AgentSessionAbort.call(
        agent: @agent,
        task: @task,
        creative: @creative,
        comment: @reply_comment || @original_comment
      )
    end
  end
end
