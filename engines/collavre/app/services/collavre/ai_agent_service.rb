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
        log_action("start", { message: "Starting agent execution" })

        # Build context and messages
        @original_comment = find_original_comment
        messages = build_messages
        log_action("prompt_generated", { messages: messages })

        # Prepare rendering context and prompts
        @creative = find_creative
        rendering_context = prepare_rendering_context
        system_prompt = render_system_prompt(rendering_context)

        # Create placeholder comment if needed
        @reply_comment = create_reply_comment_if_needed

        # Initialize lifecycle manager
        @lifecycle_manager = AiAgent::AgentLifecycleManager.new(
          task: @task,
          agent: @agent,
          creative: @creative
        )

        # Initialize response streamer
        @streamer = AiAgent::ResponseStreamer.new(
          reply_comment: @reply_comment,
          creative: @creative
        )

        @lifecycle_manager.broadcast_status("thinking")

        # Execute AI chat with streaming
        client = build_ai_client(system_prompt)
        stream_response(client, messages)

        log_action("completion", { response: @streamer.content })

        # Finalize and dispatch (skip A2A for review-flow updates)
        finalized_comment = finalize_response
        dispatch_a2a(finalized_comment) unless @finalizer&.review_flow

        @lifecycle_manager.broadcast_status("idle")

        @streamer.content
      end
    rescue ApprovalPendingError => e
      AiAgent::ApprovalHandler.new(
        task: @task, agent: @agent, context: @context,
        creative: @creative, reply_comment: @reply_comment
      ).handle(e)
      raise
    rescue CancelledError
      handle_cancelled
      raise
    end

    private

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
        topic_id: @original_comment.topic_id
      )
    end

    def build_ai_client(system_prompt)
      AiClient.new(
        vendor: @agent.llm_vendor,
        model: @agent.llm_model,
        system_prompt: system_prompt,
        llm_api_key: @agent.llm_api_key,
        context: {
          creative: @creative,
          user: @agent,
          task: @task,
          comment: @reply_comment || @original_comment
        }
      )
    end

    def stream_response(client, messages)
      client.chat(messages, tools: @agent.tools || []) do |delta|
        @lifecycle_manager.check_cancelled!
        @streamer.append(delta)
        @lifecycle_manager.heartbeat_if_needed
      end
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

    def handle_cancelled
      @lifecycle_manager.handle_cancelled(
        reply_comment: @reply_comment,
        response_content: @streamer.content
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
  end
end
