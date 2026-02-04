module Collavre
  class AiAgentService
    # Minimum interval (in seconds) between streaming broadcasts to avoid excessive updates
    STREAM_THROTTLE_INTERVAL = 0.1

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
        response_content = ""

        # Enrich context for rendering
        rendering_context = @context.dup
        if @context.dig("creative", "id")
          creative = Creative.find_by(id: @context["creative"]["id"])
          rendering_context["creative"] = creative.as_json if creative
        end

        rendered_system_prompt = AiSystemPromptRenderer.new(
          template: @agent.system_prompt,
          context: rendering_context
        ).render

        target_comment_id = @context.dig("comment", "id")
        original_comment = target_comment_id ? Comment.find_by(id: target_comment_id) : nil

        @creative = @context.dig("creative", "id") ? Creative.find_by(id: @context["creative"]["id"]) : nil

        # Broadcast "thinking" status via presence channel
        broadcast_agent_status("thinking")

        # Append a temporary streaming element to the comments list
        if @creative
          append_streaming_element
        end

        client = AiClient.new(
          vendor: @agent.llm_vendor,
          model: @agent.llm_model,
          system_prompt: rendered_system_prompt,
          llm_api_key: @agent.llm_api_key,
          context: {
            creative: @creative,
            user: @agent,
            task: @task,
            comment: original_comment
          }
        )

        last_broadcast_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)

        client.chat(messages, tools: @agent.tools || []) do |delta|
          response_content += delta

          # Update the temporary streaming element with accumulated content (throttled)
          now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          if @creative && (now - last_broadcast_at) >= STREAM_THROTTLE_INTERVAL
            broadcast_agent_status("streaming")
            replace_streaming_element(response_content)
            last_broadcast_at = now
          end
        end

        # Final broadcast of streaming content (ensure last chunk is shown)
        replace_streaming_element(response_content) if @creative && response_content.present?

        # Log completion
        log_action("completion", { response: response_content })

        # Remove the temporary streaming element
        remove_streaming_element if @creative

        # Create the actual comment with final content
        if original_comment && response_content.present?
          reply = original_comment.creative.comments.create!(
            content: response_content,
            user: @agent,
            topic_id: original_comment.topic_id
          )
          log_action("reply_created", { comment_id: reply.id, content: response_content })

          # Re-associate activity logs from the trigger comment to the reply comment
          # so that LLM interaction logs appear on the AI's answer, not the user's question
          reassociate_activity_logs(original_comment, reply)
        elsif target_comment_id && response_content.present?
          reply_to_comment(target_comment_id, response_content)
        end

        # Broadcast "idle" status
        broadcast_agent_status("idle")
      end
    rescue ApprovalPendingError => e
      handle_approval_pending(e)
      raise # Re-raise to signal the job to handle status
    end

    private

    def streaming_element_id
      "agent-streaming-#{@task.id}"
    end

    def broadcast_agent_status(status)
      return unless @creative

      CommentsPresenceChannel.broadcast_agent_status(
        @creative.effective_origin.id,
        status: status,
        agent_id: @agent.id,
        agent_name: @agent.display_name,
        task_id: @task.id
      )
    end

    def append_streaming_element
      Turbo::StreamsChannel.broadcast_append_to(
        [ @creative, :comments ],
        target: "comments-list",
        html: streaming_element_html("")
      )
    end

    def replace_streaming_element(content)
      Turbo::StreamsChannel.broadcast_replace_to(
        [ @creative, :comments ],
        target: streaming_element_id,
        html: streaming_element_html(content)
      )
    end

    def remove_streaming_element
      Turbo::StreamsChannel.broadcast_remove_to(
        [ @creative, :comments ],
        target: streaming_element_id
      )
    end

    def streaming_element_html(content)
      avatar_html = if @agent.respond_to?(:avatar_url) && @agent.avatar_url.present?
        "<img src=\"#{@agent.avatar_url}\" alt=\"\" width=\"20\" height=\"20\" " \
          "class=\"avatar comment-avatar\" style=\"border-radius: 50%;\" />"
      else
        ""
      end

      escaped_content = ERB::Util.html_escape(content)
      "<div id=\"#{streaming_element_id}\" class=\"comment-item agent-streaming\">" \
        "#{avatar_html}" \
        "<strong>#{ERB::Util.html_escape(@agent.display_name)}</strong> " \
        "<span class=\"comment-content\">#{escaped_content}</span>" \
        "</div>"
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
      # This logic mimics the old AiResponder but adapts to the new context structure
      # We might need to fetch the creative and history based on context

      messages = []

      # Add context-specific messages
      # For comment_created, we want the creative context and chat history

      if @context["creative"]
        # We might need to re-fetch creative to get the full markdown if it's not in context
        # But for efficiency, let's assume we fetch it if ID is present
        creative_id = @context.dig("creative", "id")
        if creative_id
          creative = Creative.find_by(id: creative_id)
          if creative
            markdown = ApplicationController.helpers.render_creative_tree_markdown([ creative ], 1, true)
            messages << { role: "user", parts: [ { text: "Creative:\n#{markdown}" } ] }
          end
        end
      end

      # Add chat history
      if @context.dig("creative", "id")
        creative_id = @context["creative"]["id"]
        # Fetch comments for context, excluding private ones unless owned by the user
        # We need to be careful about which comments to include.
        # For now, let's include non-private comments.

        # We need to know who the "user" is to determine roles.
        # In the new system, the agent is @agent.

        # We need to filter by topic_id to maintain conversation context
        trigger_comment_id = @context.dig("comment", "id")
        trigger_comment = Comment.find_by(id: trigger_comment_id)
        topic_id = trigger_comment&.topic_id

        Comment.where(creative_id: creative_id, private: false)
               .where(topic_id: topic_id)
               .order(created_at: :desc)
               .limit(50) # Limit history to avoid context window issues
               .reverse # Re-order to chronological for the AI
               .each do |c|
          next if c.id == @context.dig("comment", "id") # Skip the current trigger comment if it's in the list (it shouldn't be usually if we query right, but good to be safe)

          role = (c.user_id == @agent.id) ? "model" : "user"
          content = c.content

          # Strip mentions of the agent from user messages to clean up context
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

      # Add the trigger payload
      payload_text = @context.dig("comment", "content") || @context.to_json
      messages << { role: "user", parts: [ { text: payload_text } ] }

      messages
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

    def handle_approval_pending(error)
      # Broadcast idle status to clear typing indicator
      broadcast_agent_status("idle")

      # Remove temporary streaming element if present
      remove_streaming_element if @creative

      # Store pending tool call info in task
      @task.update!(
        status: "pending_approval",
        pending_tool_call: {
          tool_name: error.tool_name,
          tool_call_id: error.tool_call_id,
          arguments: error.tool_arguments,
          requested_at: Time.current.iso8601
        }
      )

      # Log the pending approval action
      log_action("pending_approval", error.to_h)

      # Create approval request comment
      create_approval_comment(error)
    end

    def create_approval_comment(error)
      return unless @creative

      # Determine approver - creative owner or the user who triggered the conversation
      approver = @creative.user || User.find_by(id: @context.dig("comment", "user_id"))
      return unless approver

      # Build approval action payload
      action_payload = {
        action: "execute_tool",
        tool_name: error.tool_name,
        arguments: error.tool_arguments,
        resume: {
          task_id: @task.id,
          tool_call_id: error.tool_call_id
        }
      }

      # Format arguments for display
      args_display = if error.tool_arguments.present?
                       JSON.pretty_generate(error.tool_arguments)
      else
                       "(no arguments)"
      end

      content = <<~CONTENT.strip
        🔧 **Tool Approval Required**

        **#{error.tool_name}** wants to execute with the following arguments:

        ```json
        #{args_display}
        ```

        Please approve or reject this action.
      CONTENT

      # Get topic_id from the original comment if available
      original_comment = Comment.find_by(id: @context.dig("comment", "id"))
      topic_id = original_comment&.topic_id

      Comment.create!(
        creative: @creative,
        content: content,
        user: @agent, # Posted by the agent requesting approval
        approver: approver,
        action: JSON.pretty_generate(action_payload),
        topic_id: topic_id,
        private: false
      )
    end
  end
end
