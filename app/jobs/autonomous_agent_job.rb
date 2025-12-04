class AutonomousAgentJob < ApplicationJob
  queue_as :default

  def perform(agent_run_id)
    agent_run = AgentRun.find_by(id: agent_run_id)
    return unless agent_run
    return if agent_run.status == "success" || agent_run.status == "error"

    # Transition to running if pending
    agent_run.update!(status: "running") if agent_run.status == "pending"

    # Build conversation history
    builder = AiConversationBuilder.new(
      creative: agent_run.creative,
      ai_user: agent_run.ai_user,
      helpers: ApplicationController.helpers
    )

    # Base messages from creative and comments
    base_messages = builder.build_messages(include_history: true)

    # Append agent transcript (previous iterations)
    # Transcript is expected to be a list of message hashes
    transcript_messages = agent_run.transcript.map(&:deep_symbolize_keys)
    messages = base_messages + transcript_messages

    # Prepare system prompt
    system_prompt = AiSystemPromptRenderer.render(
      template: agent_run.ai_user.system_prompt,
      context: {
        ai_user: agent_run.ai_user.attributes,
        creative: agent_run.creative.attributes,
        goal: agent_run.goal,
        context: agent_run.context
      }
    )

    # Initialize Agent Client
    client = AgentClient.new(
      vendor: agent_run.ai_user.llm_vendor,
      model: agent_run.ai_user.llm_model,
      system_prompt: system_prompt,
      llm_api_key: agent_run.ai_user.llm_api_key,
      agent_run_id: agent_run.id
    )

    # Execute Agent Step
    # We use the client to chat, which will execute tools via the wrapper.
    # The response will be the final answer or the result of the turn.

    response_text = client.chat(messages, tools: agent_run.ai_user.tools || [])

    if response_text.present?
      # Update transcript with the new interaction
      # Note: We only have the final response here.
      # Ideally we should capture the tool calls in the transcript too.
      # But AgentClient (via AiClient) doesn't return the conversation object.
      # However, we have recorded AgentActions in the DB.

      # For now, append the assistant response to transcript
      new_transcript = agent_run.transcript + [ { role: "model", parts: [ { text: response_text } ] } ]

      agent_run.update!(
        transcript: new_transcript,
        status: "success", # For now, assume one-shot or completion after response
        state: "completed"
      )

      # If we want a loop, we should check if the goal is met or if the agent wants to continue.
      # But for this iteration, let's assume it runs once per job.
      # If it needs to run again, it should be scheduled.
      # Or maybe the agent itself decides?

      # TODO: Implement multi-turn loop logic if needed.
      # Update comment if comment_id is present in context
      if agent_run.context["comment_id"]
        comment = Comment.find_by(id: agent_run.context["comment_id"])
        comment&.update!(content: response_text)
      end
    else
      agent_run.update!(status: "error")

      if agent_run.context["comment_id"]
        comment = Comment.find_by(id: agent_run.context["comment_id"])
        comment&.update!(content: "Error: No response from AI agent.")
      end
    end

  rescue => e
    agent_run.update!(status: "error", context: agent_run.context.merge(error: e.message))
    raise e
  end
end
