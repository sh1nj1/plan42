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
  # A packaged desktop app keeps its Rails source tree inside the read-only
  # application bundle. Put the LLM log alongside the other writable desktop
  # logs instead of trying to create `Contents/Resources/app/log` at boot.
  log_root = ENV["COLLAVRE_DATA_DIR"].presence || Rails.root
  config.log_file = File.join(log_root, "log", "ruby_llm.log")
  # Mirror the app's log level instead of hardcoding DEBUG. At DEBUG the Faraday
  # :logger middleware writes full request/response bodies to ruby_llm.log
  # (connection.rb: `bodies: RubyLLM.logger.debug?`). Provider error bodies arrive
  # tagged ASCII-8BIT, so non-ASCII text (e.g. Korean) fails to transcode into the
  # UTF-8 log and floods stderr with "log writing failed" lines. Production runs at
  # INFO, which silences body logging; development stays at DEBUG for full tracing.
  config.log_level = Rails.logger&.level || Logger::INFO
  config.log_stream_debug = Rails.logger&.debug? || false
end
