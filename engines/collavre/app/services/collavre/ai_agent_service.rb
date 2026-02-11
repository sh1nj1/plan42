module Collavre
  class AiAgentService
    # Minimum interval (in seconds) between streaming updates to avoid excessive DB writes
    STREAM_THROTTLE_INTERVAL = 0.1
    # Minimum interval (in seconds) between cancellation checks to avoid excessive DB queries
    CANCEL_CHECK_INTERVAL = 1.0

    def initialize(task)
      @task = task
      @agent = task.agent
      @context = task.trigger_event_payload
    end

    def call
      Current.set(user: @agent) do
        # Log start action
        log_action("start", { message: "Starting agent execution" })

        # Prepare messages for AI
        messages = build_messages

        # Log prompt generation
        log_action("prompt_generated", { messages: messages })

        # Call AI Client
        @response_content = ""

        # Enrich context for rendering
        rendering_context = @context.dup
        if @context.dig("creative", "id")
          creative = Creative.find_by(id: @context["creative"]["id"])
          rendering_context["creative"] = creative.as_json if creative
        end

        # Add agent collaboration context
        agent_context = build_agent_context(creative)
        rendering_context.merge!(agent_context)

        rendered_system_prompt = AiSystemPromptRenderer.new(
          template: @agent.system_prompt,
          context: rendering_context
        ).render

        # Append collaboration guide to system prompt
        collaboration_prompt = build_collaboration_prompt(creative)
        rendered_system_prompt = "#{rendered_system_prompt}\n\n#{collaboration_prompt}" if collaboration_prompt.present?

        # Create a placeholder comment to stream into
        target_comment_id = @context.dig("comment", "id")
        @original_comment = target_comment_id ? Comment.find_by(id: target_comment_id) : nil
        @reply_comment = nil

        if @original_comment
          @reply_comment = @original_comment.creative.comments.create!(
            content: Comment::STREAMING_PLACEHOLDER_CONTENT, # Placeholder — replaced during streaming
            user: @agent,
            topic_id: @original_comment.topic_id
          )
        end

        @creative = @context.dig("creative", "id") ? Creative.find_by(id: @context["creative"]["id"]) : nil

        # Broadcast "thinking" status via presence channel
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
        @last_cancel_check_at = last_broadcast_at

        client.chat(messages, tools: @agent.tools || []) do |delta|
          check_cancelled!
          @response_content += delta

          # Stream updates to placeholder comment (throttled)
          now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          if @reply_comment && (now - last_broadcast_at) >= STREAM_THROTTLE_INTERVAL
            @reply_comment.update_column(:content, @response_content)
            @reply_comment.broadcast_update_to(
              [ @reply_comment.creative, :comments ],
              partial: "collavre/comments/comment"
            )
            last_broadcast_at = now
          end
        end

        # Log completion
        log_action("completion", { response: @response_content })

        # Final save to ensure everything is consistent and trigger final callbacks
        if @reply_comment
          if @response_content.present?
            # Review message handling: update the quoted comment if agent has edit permission
            if @original_comment&.review_message? && handle_review_message(@response_content)
              # Successfully updated quoted comment; destroy the placeholder reply
              @reply_comment.destroy!
            else
              # Force dirty tracking since update_column bypassed it during streaming
              @reply_comment.content_will_change!
              @reply_comment.update!(content: @response_content)
              log_action("reply_created", { comment_id: @reply_comment.id, content: @response_content })

              # Re-associate activity logs from the trigger comment to the reply comment
              reassociate_activity_logs(@original_comment, @reply_comment)
            end
          else
            @reply_comment.destroy!
          end
        elsif target_comment_id && @response_content.present?
          reply_to_comment(target_comment_id, @response_content)
        end

        # Broadcast "idle" status
        broadcast_agent_status("idle")

        @response_content
      end
    rescue ApprovalPendingError => e
      handle_approval_pending(e)
      raise # Re-raise to signal the job to handle status
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
      # Save accumulated content to the placeholder comment before stopping
      if @reply_comment
        if @response_content.present?
          @reply_comment.content_will_change!
          @reply_comment.update!(content: @response_content)
          log_action("reply_created", { comment_id: @reply_comment.id, content: @response_content, partial: true })
          reassociate_activity_logs(@original_comment, @reply_comment)
        else
          @reply_comment.destroy!
        end
      end

      broadcast_agent_status("idle")
      log_action("cancelled", { message: "Task cancelled by user" })
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

    def build_messages
      messages = []

      if @context["creative"]
        creative_id = @context.dig("creative", "id")
        if creative_id
          creative = Creative.find_by(id: creative_id)
          if creative
            markdown = ApplicationController.helpers.render_creative_tree_markdown([ creative ], 1, true)
            messages << { role: "user", parts: [ { text: "Creative:\n#{markdown}" } ] }
          end
        end
      end

      if @context.dig("creative", "id")
        creative_id = @context["creative"]["id"]

        trigger_comment_id = @context.dig("comment", "id")
        trigger_comment = Comment.find_by(id: trigger_comment_id)
        topic_id = trigger_comment&.topic_id

        Comment.where(creative_id: creative_id, private: false)
               .where(topic_id: topic_id)
               .order(created_at: :desc)
               .limit(50)
               .reverse
               .each do |c|
          next if c.id == @context.dig("comment", "id")

          role = (c.user_id == @agent.id) ? "model" : "user"
          content = c.content

          if role == "user"
            if content.match?(/\A@#{Regexp.escape(@agent.name)}:/i)
              content = content.sub(/\A@#{Regexp.escape(@agent.name)}:\s*/i, "")
            elsif content.match?(/\A@#{Regexp.escape(@agent.name)}\s+/i)
              content = content.sub(/\A@#{Regexp.escape(@agent.name)}\s+/i, "")
            end
          end

          messages << { role: role, parts: [ { text: content } ] }
        end
      end

      payload_text = @context.dig("comment", "content") || @context.to_json

      # Add review context if this is a review message
      trigger_comment_id = @context.dig("comment", "id")
      trigger_comment = trigger_comment_id ? Comment.find_by(id: trigger_comment_id) : nil
      if trigger_comment&.review_message?
        review_context = I18n.t("collavre.ai_agent.review.context")
        payload_text = "#{review_context}\n\n#{payload_text}"
      end

      messages << { role: "user", parts: [ { text: payload_text } ] }

      messages
    end

    def handle_review_message(response_content)
      quoted_comment = @original_comment.quoted_comment
      return false unless quoted_comment
      return false unless quoted_comment.user_id == @agent.id

      quoted_comment.update!(content: response_content)
      log_action("review_updated", {
        quoted_comment_id: quoted_comment.id,
        original_comment_id: @original_comment.id,
        content: response_content
      })
      true
    end

    def reply_to_comment(comment_id, content)
      original_comment = Comment.find_by(id: comment_id)
      return unless original_comment

      reply = original_comment.creative.comments.create!(
        content: content,
        user: @agent,
        topic_id: original_comment.topic_id
      )

      log_action("reply_created", { comment_id: reply.id, content: content })
      reassociate_activity_logs(original_comment, reply)
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
        sender: @context["sender"]
      ).to_collaboration_prompt
    end

    def handle_approval_pending(error)
      # Clean up placeholder comment if exists
      @reply_comment&.destroy! if @reply_comment&.content == Comment::STREAMING_PLACEHOLDER_CONTENT

      broadcast_agent_status("idle")

      @task.update!(
        status: "pending_approval",
        pending_tool_call: {
          tool_name: error.tool_name,
          tool_call_id: error.tool_call_id,
          arguments: error.tool_arguments,
          requested_at: Time.current.iso8601
        }
      )

      log_action("pending_approval", error.to_h)
      create_approval_comment(error)
    end

    def create_approval_comment(error)
      return unless @creative

      approver = @creative.user || User.find_by(id: @context.dig("comment", "user_id"))
      return unless approver

      action_payload = {
        action: "execute_tool",
        tool_name: error.tool_name,
        arguments: error.tool_arguments,
        resume: {
          task_id: @task.id,
          tool_call_id: error.tool_call_id
        }
      }

      args_display = if error.tool_arguments.present?
                       JSON.pretty_generate(error.tool_arguments)
      else
                       I18n.t("collavre.ai_agent.approval.no_arguments")
      end

      content = I18n.t(
        "collavre.ai_agent.approval.message",
        tool_name: error.tool_name,
        arguments: args_display
      )

      original_comment = Comment.find_by(id: @context.dig("comment", "id"))
      topic_id = original_comment&.topic_id

      Comment.create!(
        creative: @creative,
        content: content,
        user: @agent,
        approver: approver,
        action: JSON.pretty_generate(action_payload),
        topic_id: topic_id,
        private: false
      )
    end
  end
end
