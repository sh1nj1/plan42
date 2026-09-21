# frozen_string_literal: true

Rails.application.config.to_prepare do
  Collavre::AgentHealth::EndpointRequest::VENDORS.each do |vendor|
    Collavre::AgentHealth.register(vendor, Collavre::AgentHealth::OpenaiEndpointChecker)
  end
end
