# frozen_string_literal: true

module Collavre
  module AiUsageTracking
    private

    def start_usage_tracking(measurement: nil)
      @usage_recorder = LlmUsage::Recorder.new(context: context, vendor: vendor, model: model, measurement: measurement) if @log_interactions
    end

    def install_usage_tracking(chat)
      chat.after_message { |response| record_usage_response(response) } if chat.respond_to?(:after_message)
    end

    def record_usage_response(response)
      @usage_recorder&.record(response)
    rescue StandardError => e
      Rails.logger.error("Failed to persist LLM usage: #{e.class}: #{e.message}")
    end

    def finish_usage_tracking(response = nil)
      @usage_recorder&.finish(response)
    rescue StandardError => e
      Rails.logger.error("Failed to persist LLM usage: #{e.class}: #{e.message}")
    end
  end
end
