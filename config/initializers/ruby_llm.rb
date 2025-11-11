# frozen_string_literal: true

return unless defined?(RubyLLM)

RubyLLM.configure do |config|
  config.gemini_api_key = ENV["GEMINI_API_KEY"]
end
