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

    client = AiClient.new(
      vendor: @agent.llm_vendor,
      model: @agent.llm_model,
      system_prompt: @agent.system_prompt,
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
        creative = Creative.find(creative_id)
        markdown = ApplicationController.helpers.render_creative_tree_markdown([ creative ], 1, true)
        messages << { role: "user", parts: [ { text: "Creative:\n#{markdown}" } ] }
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
