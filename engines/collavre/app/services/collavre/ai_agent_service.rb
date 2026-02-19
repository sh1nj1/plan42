module Collavre
  class AiAgentService
    # Minimum interval (in seconds) between streaming updates to avoid excessive DB writes
    STREAM_THROTTLE_INTERVAL = 0.1
    # Minimum interval (in seconds) between cancellation checks to avoid excessive DB queries
    CANCEL_CHECK_INTERVAL = 1.0
    # Interval (in seconds) between agent_status heartbeats during streaming
    AGENT_STATUS_HEARTBEAT_INTERVAL = 3.0

    def initialize(task)
      @task = task
      @agent = task.agent
      @context = task.trigger_event_payload
    end

    def call
      Current.set(user: @agent) do
        log_action("start", { message: "Starting agent execution" })

        target_comment_id = @context.dig("comment", "id")
        @original_comment = target_comment_id ? Comment.find_by(id: target_comment_id) : nil

        messages = AiAgent::MessageBuilder.new(
          agent: @agent, context: @context, original_comment: @original_comment
        ).build

        log_action("prompt_generated", { messages: messages })

        @response_content = ""

        rendering_context = @context.dup
        if @context.dig("creative", "id")
          creative = Creative.find_by(id: @context["creative"]["id"])
          rendering_context["creative"] = creative.as_json if creative
        end

        agent_context = build_agent_context(creative)
        rendering_context.merge!(agent_context)

        rendered_system_prompt = AiSystemPromptRenderer.new(
          template: @agent.system_prompt,
          context: rendering_context
        ).render

        collaboration_prompt = build_collaboration_prompt(creative)
        rendered_system_prompt = "#{rendered_system_prompt}\n\n#{collaboration_prompt}" if collaboration_prompt.present?

        @reply_comment = nil

        if @original_comment
          @reply_comment = @original_comment.creative.comments.create!(
            content: Comment::STREAMING_PLACEHOLDER_CONTENT,
            user: @agent,
            topic_id: @original_comment.topic_id
          )
        end

        @creative = @context.dig("creative", "id") ? Creative.find_by(id: @context["creative"]["id"]) : nil

        broadcast_agent_status("thinking")

        client = AiClient.new(
          vendor: @agent.llm_vendor,
          model: @agent.llm_model,
          system_prompt: rendered_system_prompt,
          llm_api_key: @agent.llm_api_key,
          context: {
            creative: @creative,
            user: @agent,
            task: @task,
            comment: @reply_comment || @original_comment
          }
        )

        last_broadcast_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        last_heartbeat_at = last_broadcast_at
        @last_cancel_check_at = last_broadcast_at

        client.chat(messages, tools: @agent.tools || []) do |delta|
          check_cancelled!
          @response_content += delta

          now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          if @reply_comment && (now - last_broadcast_at) >= STREAM_THROTTLE_INTERVAL
            @reply_comment.update_column(:content, @response_content)
            @reply_comment.broadcast_update_to(
              [ @reply_comment.creative, :comments ],
              partial: "collavre/comments/comment",
              locals: { comment: @reply_comment, streaming: true }
            )
            last_broadcast_at = now
          end

          # Periodic agent_status heartbeat so clients know we're still streaming
          if (now - last_heartbeat_at) >= AGENT_STATUS_HEARTBEAT_INTERVAL
            broadcast_agent_status("streaming")
            last_heartbeat_at = now
          end
        end

        log_action("completion", { response: @response_content })

        finalize_response

        broadcast_agent_status("idle")

        @response_content
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

    def check_cancelled!
      now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      return if (now - @last_cancel_check_at) < CANCEL_CHECK_INTERVAL

      @last_cancel_check_at = now
      raise CancelledError if @task.reload.status == "cancelled"
    end

    def handle_cancelled
      if @reply_comment
        if @response_content.present?
          @reply_comment.content_will_change!
          @reply_comment.update!(content: @response_content)
          @reply_comment.broadcast_update_to(
            [ @reply_comment.creative, :comments ],
            partial: "collavre/comments/comment",
            locals: { comment: @reply_comment, streaming: false }
          )
          log_action("reply_created", { comment_id: @reply_comment.id, content: @response_content, partial: true })
          reassociate_activity_logs(@original_comment, @reply_comment)
        else
          @reply_comment.destroy!
        end
      end

      broadcast_agent_status("idle")
      log_action("cancelled", { message: "Task cancelled by user" })
    end

    def finalize_response
      review_handler = AiAgent::ReviewHandler.new(@original_comment, @agent)

      if @reply_comment
        if @response_content.present?
          if @original_comment&.review_message? && review_handler.handle(@response_content, task: @task)
            review_handler.add_completion_reaction
            reassociate_activity_logs(@reply_comment, @original_comment.quoted_comment)
            @reply_comment.destroy!
          else
            @reply_comment.content_will_change!
            @reply_comment.update!(content: @response_content)
            @reply_comment.broadcast_update_to(
              [ @reply_comment.creative, :comments ],
              partial: "collavre/comments/comment",
              locals: { comment: @reply_comment, streaming: false }
            )
            log_action("reply_created", { comment_id: @reply_comment.id, content: @response_content })
            reassociate_activity_logs(@original_comment, @reply_comment)
            dispatch_a2a_if_needed
          end
        else
          @reply_comment.destroy!
        end
      elsif @context.dig("comment", "id") && @response_content.present?
        reply_to_comment(@context["comment"]["id"], @response_content)
      end
    end

    def broadcast_agent_status(status, content: nil)
      return unless @creative

      CommentsPresenceChannel.broadcast_agent_status(
        @creative.effective_origin.id,
        status: status,
        agent_id: @agent.id,
        agent_name: @agent.display_name,
        task_id: @task.id,
        content: content,
        source_creative_id: @creative.id
      )
    end

    def log_action(type, payload, result = nil)
      @task.task_actions.create!(
        action_type: type,
        payload: payload,
        result: result,
        status: "done"
      )
    end

    def reply_to_comment(comment_id, content)
      original_comment = Comment.find_by(id: comment_id)
      return unless original_comment

      @reply_comment = original_comment.creative.comments.create!(
        content: content,
        user: @agent,
        topic_id: original_comment.topic_id
      )

      log_action("reply_created", { comment_id: @reply_comment.id, content: content })
      reassociate_activity_logs(original_comment, @reply_comment)
      dispatch_a2a_if_needed
    end

    def dispatch_a2a_if_needed
      return unless @reply_comment&.content.present?

      # Find all mentioned AI agents anywhere in the response (not just at the start)
      mentioned_agents = MentionParser.resolve_all_users(@reply_comment.content).select(&:ai_user?)
      return if mentioned_agents.empty?

      creative = @reply_comment.creative

      mentioned_agents.each do |mentioned_user|
        if creative
          context = { "creative" => { "id" => creative.id }, "topic" => { "id" => @reply_comment.topic_id } }
          Orchestration::LoopBreaker.new(context).record_interaction(@agent.id, mentioned_user.id, creative.id)
        end
      end

      # Dispatch event — downstream Matcher will route to the correct agent(s)
      SystemEvents::Dispatcher.dispatch("comment_created", {
        comment: { id: @reply_comment.id, content: @reply_comment.content, user_id: @reply_comment.user_id },
        creative: { id: creative&.id, description: creative&.description },
        topic: { id: @reply_comment.topic_id },
        chat: { content: @reply_comment.content }
      })
    rescue StandardError => e
      Rails.logger.error("[AiAgentService] A2A dispatch failed: #{e.message}")
    end

    def reassociate_activity_logs(from_comment, to_comment)
      ActivityLog.where(comment: from_comment, user: @agent)
                 .update_all(comment_id: to_comment.id)
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
