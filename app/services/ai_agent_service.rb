class AiAgentService
  def initialize(task)
    @task = task
    @agent = task.agent
    @context = task.trigger_event_payload
  end

  def call
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

    # we may pass event payload also to the AI client for more context if needed - TODO
    client = AiClient.new(
      vendor: @agent.llm_vendor,
      model: @agent.llm_model,
      system_prompt: rendered_system_prompt,
      llm_api_key: @agent.llm_api_key
    )

    client.chat(messages, tools: @agent.tools || []) do |delta|
      response_content += delta
      # We could stream updates to the task or a related comment here if needed
    end

    # Log completion
    log_action("completion", { response: response_content })

    # Handle the response (e.g., create a comment reply)
    # For now, we assume the context has a comment_id to reply to
    if @context.dig("comment", "id") && response_content.present?
      reply_to_comment(@context["comment"]["id"], response_content)
    end
  end

  private

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

      Comment.where(creative_id: creative_id, private: false)
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
      user: @agent
    )

    log_action("reply_created", { comment_id: reply.id, content: content })
  end
end
