# frozen_string_literal: true

module Collavre
  module Screening
    # One judge that answers Screening::QUESTIONS. The system screener uses the
    # deployment's Typesafe credentials; an agent screener is a judge agent
    # shared on the creative and bills its owner, like TriggerLoopHelpers.
    class Screener
      class MissingCredentialsError < StandardError; end

      TIMEOUT_SECONDS = 30

      attr_reader :id, :model

      def self.system(agent:, task:)
        new(id: "system", vendor: "typesafe", model: SystemSetting.screening_model,
            api_key: ENV["TYPESAFE_API_KEY"], gateway_url: ENV["TYPESAFE_API_BASE"].presence,
            usage_user: agent, task: task)
      end

      def self.agent(judge, task:)
        new(id: "agent:#{judge.id}", vendor: judge.llm_vendor, model: judge.llm_model,
            api_key: judge.llm_api_key.presence || judge.creator&.llm_api_key,
            gateway_url: judge.gateway_url.presence || judge.creator&.gateway_url,
            usage_user: judge, task: task)
      end

      def initialize(id:, vendor:, model:, api_key:, gateway_url:, usage_user:, task:)
        @id, @vendor, @model = id, vendor, model
        @api_key, @gateway_url = api_key, gateway_url
        @usage_user, @task = usage_user, task
      end

      def system?
        id == "system"
      end

      def judge(input)
        raise MissingCredentialsError, "Screening has no #{@vendor} API key" if system? && @api_key.blank?

        client.judge(input, questions: QUESTIONS)
      end

      private

      def client
        AiClient.new(
          vendor: @vendor, model: @model, system_prompt: SYSTEM_PROMPT,
          llm_api_key: @api_key, gateway_url: @gateway_url,
          request_timeout_seconds: TIMEOUT_SECONDS,
          context: { user: @usage_user, usage_source_task: @task, evaluation_session_id: SecureRandom.uuid }
        )
      end
    end
  end
end
