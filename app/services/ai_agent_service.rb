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

    # Create a placeholder comment to stream into
    target_comment_id = @context.dig("comment", "id")
    reply_comment = nil

    if target_comment_id
      original_comment = Comment.find_by(id: target_comment_id)
      if original_comment
        reply_comment = original_comment.creative.comments.create!(
          content: "...", # Placeholder
          user: @agent,
          topic_id: original_comment.topic_id
        )
      end
    end

    # we may pass event payload also to the AI client for more context if needed - TODO
    client = AiClient.new(
      vendor: @agent.llm_vendor,
      model: @agent.llm_model,
      system_prompt: rendered_system_prompt,
      llm_api_key: @agent.llm_api_key,
      context: {
        creative: @context.dig("creative", "id") ? Creative.find_by(id: @context["creative"]["id"]) : nil,
        user: @agent,
        comment: reply_comment || (@context.dig("comment", "id") ? Comment.find_by(id: @context["comment"]["id"]) : nil)
      }
    )

    client.chat(messages, tools: @agent.tools || []) do |delta|
      response_content += delta

      # Stream updates to the comment
      if reply_comment
        # We use update_column to avoid triggering full model callbacks/validations on every chunk
        # but we *do* want to broadcast the update.
        # However, calling 'update' trigger callbacks which might be heavy.
        # Let's try direct broadcast or a lighter update.
        # For now, let's just update the content.
        # To avoid being too chatty we could throttle, but let's try direct updates first.

        reply_comment.update_column(:content, response_content)

        # Manually trigger broadcast for the content update
        # We use broadcast_update_to to immediately stream the update
        reply_comment.broadcast_update_to([ reply_comment.creative, :comments ])
      end
    end

    # Log completion
    log_action("completion", { response: response_content })

    # Final save to ensure everything is consistent and trigger final callbacks
    if reply_comment
      if response_content.present?
        reply_comment.update!(content: response_content)
        log_action("reply_created", { comment_id: reply_comment.id, content: response_content })
      else
        reply_comment.destroy!
      end
    elsif target_comment_id && response_content.present?
      # Fallback if creation failed earlier or logic changed
      reply_to_comment(target_comment_id, response_content)
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
  end
end
