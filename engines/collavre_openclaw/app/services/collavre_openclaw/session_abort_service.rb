# frozen_string_literal: true

module CollavreOpenclaw
  # Aborts an in-flight OpenClaw gateway session for a cancelled task.
  # Registered into Collavre::AgentSessionAbort so core stays vendor-agnostic.
  class SessionAbortService
    def self.call(agent:, task:, creative: nil, comment: nil)
      new(agent: agent, task: task, creative: creative, comment: comment).call
    end

    def initialize(agent:, task:, creative: nil, comment: nil)
      @agent = agent
      @task = task
      @creative = creative
      @comment = comment
    end

    def call
      return unless defined?(CollavreOpenclaw::ConnectionManager)

      creative = @creative || @task.creative ||
                 Collavre::Creative.find_by(id: payload.dig("creative", "id"))
      comment = @comment || Collavre::Comment.find_by(id: payload.dig("comment", "id"))

      adapter = CollavreOpenclaw::OpenclawAdapter.new(
        user: @agent,
        system_prompt: "",
        context: {
          creative: creative,
          user: @agent,
          task: @task,
          comment: comment
        }
      )
      conn = CollavreOpenclaw::ConnectionManager.instance.connection_for(@agent)
      conn.chat_abort(session_key: adapter.session_key)
    end

    private

    def payload
      @task.trigger_event_payload || {}
    end
  end
end
