Rails.application.config.to_prepare do
  if defined?(Collavre::AgentSessionAbort)
    Collavre::AgentSessionAbort.register("openclaw", CollavreOpenclaw::SessionAbortService)
  end
end
