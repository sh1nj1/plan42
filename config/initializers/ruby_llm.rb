# frozen_string_literal: true

return unless defined?(RubyLLM)

# LLM API keys are registered by `Collavre::Engine` so the registry is
# populated even when the engine is mounted as a gem without this app-level
# initializer. Resolver here serves values via DB > ENV > default.

RubyLLM.configure do |config|
  config.gemini_api_key = CollavreCompat.call(Collavre::IntegrationSettings, :fetch, :gemini_api_key, boot_safe: true)
  gemini_api_base = CollavreCompat.call(Collavre::IntegrationSettings, :fetch, :gemini_api_base, boot_safe: true)
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
