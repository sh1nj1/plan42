# frozen_string_literal: true

require "test_helper"

module Collavre
  module Screening
    class ScreenerTest < ActiveSupport::TestCase
      setup do
        @owner = users(:one)
        @agent = users(:ai_bot)
        @task = Task.create!(name: "Screen", agent: @agent, status: "running")
      end

      def capture_client
        built = nil
        client = Object.new
        client.define_singleton_method(:judge) { |input, questions:| { "input" => input, "questions" => questions } }
        AiClient.stub(:new, ->(**kwargs) { built = kwargs; client }) { yield }
        built
      end

      test "system screener uses deployment Typesafe credentials and the configured model" do
        SystemSetting.create!(key: "screening_model", value: "jev-preview")
        screener = Screener.system(agent: @agent, task: @task)
        result = nil
        built = nil
        with_env("TYPESAFE_API_KEY" => "ts-key", "TYPESAFE_API_BASE" => "https://ts.example") do
          built = capture_client { result = Screener.system(agent: @agent, task: @task).judge("text") }
        end
        assert screener.system?
        assert_equal "jev-preview", screener.model
        assert_equal "typesafe", built[:vendor]
        assert_equal "ts-key", built[:llm_api_key]
        assert_equal "https://ts.example", built[:gateway_url]
        assert_equal SYSTEM_PROMPT, built[:system_prompt]
        assert_equal @agent, built.dig(:context, :user)
        assert_equal @task, built.dig(:context, :usage_source_task)
        assert_equal Screener::TIMEOUT_SECONDS, built[:request_timeout_seconds]
        assert_equal QUESTIONS, result["questions"]
      end

      test "system screener without a key fails instead of passing" do
        with_env("TYPESAFE_API_KEY" => nil) do
          assert_raises(Screener::MissingCredentialsError) { Screener.system(agent: @agent, task: @task).judge("text") }
        end
      end

      test "agent screener bills the judge, falling back to its creator's credentials" do
        @owner.update!(llm_api_key: "owner-key", gateway_url: "https://owner.example")
        judge = User.create!(email: "judge-#{SecureRandom.hex(3)}@agent.collavre.local", name: "Judge",
          password: SecureRandom.hex(16), llm_vendor: "typesafe", llm_model: "jev-latest", created_by_id: @owner.id)
        screener = Screener.agent(judge, task: @task)
        built = capture_client { screener.judge("text") }
        assert_equal "agent:#{judge.id}", screener.id
        assert_not screener.system?
        assert_equal [ "typesafe", "jev-latest", "owner-key", "https://owner.example" ],
                     built.values_at(:vendor, :model, :llm_api_key, :gateway_url)
        assert_equal judge, built.dig(:context, :user)
      end

      private

      def with_env(values)
        previous = values.keys.to_h { |key| [ key, ENV[key] ] }
        values.each { |key, value| ENV[key] = value }
        yield
      ensure
        previous.each { |key, value| ENV[key] = value }
      end
    end
  end
end
