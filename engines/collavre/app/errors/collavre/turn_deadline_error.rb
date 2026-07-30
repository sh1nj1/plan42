# frozen_string_literal: true

module Collavre
  # Raised by AgentLifecycleManager when an agent turn exceeds its wall-clock
  # deadline (SystemSetting.ai_agent_turn_deadline_seconds).
  #
  # Subclasses CancelledError deliberately: AiClient#chat re-raises
  # CancelledError but swallows every other StandardError into a streamed
  # "AI Error" message, and the CancelledError rescue chain (AiAgentService,
  # AiAgentJob) already preserves partial content, keeps the row's terminal
  # status, releases the resource slot and drains the topic queue.
  class TurnDeadlineError < CancelledError
    attr_reader :deadline_seconds

    def initialize(deadline_seconds)
      @deadline_seconds = deadline_seconds
      super("Turn exceeded the #{deadline_seconds}s deadline")
    end
  end
end
