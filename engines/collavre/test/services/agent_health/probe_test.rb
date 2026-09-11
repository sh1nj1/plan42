# frozen_string_literal: true

require "test_helper"

module Collavre
  module AgentHealth
    class ProbeTest < ActiveSupport::TestCase
      class OnlineChecker
        def initialize(agent:)
          @agent = agent
        end

        def call
          Result.new(status: :online, error: nil)
        end
      end

      class ErrorChecker
        def initialize(agent:); end

        def call
          raise RuntimeError, "checker exploded"
        end
      end

      class InvalidChecker
        def initialize(agent:); end

        def call
          Object.new
        end
      end

      setup do
        @agent = Collavre::User.create!(
          name: "Probe Agent",
          email: "probe-agent@example.test",
          password: SecureRandom.hex(24),
          llm_vendor: "probe-vendor",
          llm_model: "probe-model"
        )
      end

      teardown { AgentHealth.unregister("probe-vendor") }

      test "records a valid checker result without changing agent configuration timestamp" do
        AgentHealth.register("probe-vendor", OnlineChecker)
        configured_at = @agent.updated_at

        assert_equal :online, Probe.new(agent: @agent).call

        @agent.reload
        assert_predicate @agent, :endpoint_health_online?
        assert_not_nil @agent.endpoint_health_checked_at
        assert_nil @agent.endpoint_health_error
        assert_equal configured_at, @agent.updated_at
      end

      test "records checker exceptions as visible check errors without re-raising" do
        AgentHealth.register("probe-vendor", ErrorChecker)

        assert_equal :check_error, Probe.new(agent: @agent).call

        @agent.reload
        assert_predicate @agent, :endpoint_health_check_error?
        assert_equal "RuntimeError", @agent.endpoint_health_error
      end

      test "records invalid checker results as check errors" do
        AgentHealth.register("probe-vendor", InvalidChecker)

        assert_equal :check_error, Probe.new(agent: @agent).call
        assert_equal "ArgumentError", @agent.reload.endpoint_health_error
      end

      test "does nothing when no checker is registered" do
        checked_at = @agent.endpoint_health_checked_at

        assert_equal :unsupported, Probe.new(agent: @agent).call
        assert_nil checked_at
        assert_nil @agent.reload.endpoint_health_checked_at
        assert_predicate @agent, :endpoint_health_unknown?
      end

      test "does not write a result over changed endpoint configuration" do
        checker = Class.new do
          def initialize(agent:)
            @agent = agent
          end

          def call
            @agent.update!(gateway_url: "https://changed.example.test/v1")
            Result.new(status: :online)
          end
        end
        AgentHealth.register("probe-vendor", checker)

        assert_equal :online, Probe.new(agent: @agent).call
        assert_predicate @agent.reload, :endpoint_health_unknown?
        assert_nil @agent.endpoint_health_checked_at
      end

      test "truncates stored checker errors" do
        checker = Class.new do
          def initialize(agent:); end

          def call
            Result.new(status: :offline, error: "x" * 300)
          end
        end
        AgentHealth.register("probe-vendor", checker)

        Probe.new(agent: @agent).call

        assert_equal Probe::ERROR_LIMIT, @agent.reload.endpoint_health_error.length
      end
    end
  end
end
