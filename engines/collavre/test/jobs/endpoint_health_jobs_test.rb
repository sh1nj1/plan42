# frozen_string_literal: true

require "test_helper"

module Collavre
  class EndpointHealthJobsTest < ActiveJob::TestCase
    class Checker
      def initialize(agent:); end

      def call
        AgentHealth::Result.new(status: :online)
      end
    end

    setup do
      @agent = Collavre::User.create!(
        name: "Job Agent",
        email: "job-agent@example.test",
        password: SecureRandom.hex(24),
        llm_vendor: "job-vendor",
        llm_model: "job-model"
      )
      AgentHealth.register("job-vendor", Checker)
    end

    teardown { AgentHealth.unregister("job-vendor") }

    test "sweep enqueues only agents with registered vendor checkers" do
      probed = []

      EndpointHealthProbeJob.stub(:perform_later, ->(id) { probed << id }) do
        EndpointHealthSweepJob.perform_now
      end

      assert_includes probed, @agent.id
      assert_not_includes probed, users(:ai_bot).id

      probed.clear
      EndpointHealthProbeJob.stub(:perform_later, ->(id) { probed << id }) do
        AgentHealth.stub(:vendors, []) { EndpointHealthSweepJob.perform_now }
      end
      assert_empty probed
    end

    test "probe job executes the registered checker" do
      EndpointHealthProbeJob.perform_now(@agent.id)

      assert_predicate @agent.reload, :endpoint_health_online?
    end

    test "probe job ignores missing agents and removed checkers" do
      assert_nothing_raised { EndpointHealthProbeJob.perform_now(-1) }

      AgentHealth.unregister("job-vendor")
      assert_nothing_raised { EndpointHealthProbeJob.perform_now(@agent.id) }
      assert_predicate @agent.reload, :endpoint_health_unknown?
    end

    test "probe job contains unexpected orchestration errors" do
      AgentHealth::Probe.stub(:new, ->(**) { raise RuntimeError, "boom" }) do
        assert_nothing_raised { EndpointHealthProbeJob.perform_now(@agent.id) }
      end
    end

    test "jobs use the dedicated health queue and recurring schedule" do
      assert_equal "gateway_health", EndpointHealthProbeJob.new.queue_name
      assert_equal "gateway_health", EndpointHealthSweepJob.new.queue_name
      assert_equal 1, EndpointHealthProbeJob.new(@agent.id).concurrency_limit
      assert_equal 1.day, EndpointHealthProbeJob.new(@agent.id).concurrency_duration
      assert_equal :discard, EndpointHealthProbeJob.concurrency_on_conflict
      assert_equal "Collavre::EndpointHealthProbeJob/#{@agent.id}", EndpointHealthProbeJob.new(@agent.id).concurrency_key
      assert_equal "Collavre::EndpointHealthSweepJob/endpoint-health-sweep", EndpointHealthSweepJob.new.concurrency_key

      config = YAML.load(ERB.new(Rails.root.join("config/recurring.yml").read).result, aliases: true)
      %w[production desktop development].each do |environment|
        recurring = config.fetch(environment).fetch("endpoint_health_sweep")
        assert_equal "Collavre::EndpointHealthSweepJob", recurring.fetch("class")
        assert_equal "gateway_health", recurring.fetch("queue")
        assert_equal "every minute", recurring.fetch("schedule")
      end
    end
  end
end
