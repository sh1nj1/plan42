# frozen_string_literal: true

return unless defined?(RubyLLM)

# Register LLM API keys with the IntegrationSettings registry so the admin UI
# can surface them and `Collavre::IntegrationSettings::Resolver` can serve
# values via the DB > ENV > default precedence. Registered eagerly because
# RubyLLM is configured at boot below.
if defined?(Collavre::IntegrationSettings::Registry)
  registry = Collavre::IntegrationSettings::Registry.instance
  registry.register(:gemini_api_key,    category: "llm", sensitive: true,  requires_restart: true)
  registry.register(:openai_api_key,    category: "llm", sensitive: true,  requires_restart: false)
  registry.register(:anthropic_api_key, category: "llm", sensitive: true,  requires_restart: false)
  registry.register(:gemini_api_base,   category: "llm", sensitive: false, requires_restart: true)
end

RubyLLM.configure do |config|
  config.gemini_api_key = Collavre::IntegrationSettings.fetch(:gemini_api_key)
  gemini_api_base = Collavre::IntegrationSettings.fetch(:gemini_api_base)
  config.gemini_api_base = gemini_api_base if gemini_api_base.present?
  config.request_timeout = begin
    Collavre::SystemSetting.llm_request_timeout_seconds
  rescue StandardError
    1800
  end
  config.log_file = Rails.root.join("log", "ruby_llm.log").to_s
  config.log_level = Logger::DEBUG
  config.log_stream_debug = true
end
