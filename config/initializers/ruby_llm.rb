# frozen_string_literal: true

return unless defined?(RubyLLM)

RubyLLM.configure do |config|
  config.gemini_api_key = ENV["GEMINI_API_KEY"]
  if ENV["GEMINI_API_BASE"].present?
    config.gemini_api_base = ENV["GEMINI_API_BASE"]
  end
  config.log_file = Rails.root.join("log", "ruby_llm.log").to_s
  config.log_level = Logger::DEBUG
  config.log_stream_debug = true
end

# Monkey patch to fix RubyLlmBuilder float type mapping
# RubyLLM DSL uses `number` not `float`
# See: https://github.com/rails_mcp_engine issue
Rails.application.config.to_prepare do
  if defined?(ToolSchema::RubyLlmBuilder)
    ToolSchema::RubyLlmBuilder.singleton_class.prepend(Module.new do
      def scalar_method(type)
        case type
        when :float then :number  # RubyLLM uses `number` not `float`
        else super
        end
      end
    end)
  end
end
