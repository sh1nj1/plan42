# frozen_string_literal: true

Rails.application.config.to_prepare do
  Collavre::AgentHealth.register("openai", Collavre::AgentHealth::OpenaiEndpointChecker)
end
