require "test_helper"

class Collavre::GatewayHealthJobsTest < ActiveSupport::TestCase
  FakeClient = Struct.new(:body) do
    def health_ready
      body
    end
  end

  setup do
    @gateway = create_gateway
  end

  test "the sweep enqueues one probe per active gateway" do
    inactive = create_gateway
    inactive.update_columns(active: false)

    probed = []
    Collavre::GatewayHealthProbeJob.stub(:perform_later, ->(id) { probed << id }) do
      Collavre::GatewayHealthSweepJob.perform_now
    end

    assert_includes probed, @gateway.id
    assert_not_includes probed, inactive.id
  end

  test "the probe records a verdict for the gateway it names" do
    Collavre::CliProxy::Client.stub(:new, FakeClient.new({ "status" => "ok", "engines" => {} })) do
      Collavre::GatewayHealthProbeJob.perform_now(@gateway.id)
    end

    assert_predicate @gateway.reload, :health_ok?
  end

  # A row deactivated or deleted between the sweep and the probe must not be
  # probed: the sweep's snapshot is already a minute old by the time it runs.
  test "the probe skips a gateway that is gone or deactivated" do
    @gateway.update_columns(active: false)

    Collavre::GatewayHealthProbeJob.perform_now(@gateway.id)
    Collavre::GatewayHealthProbeJob.perform_now(-1)

    assert_nil @gateway.reload.health_checked_at
  end

  # The probe turns every transport failure into a recorded verdict, so anything
  # reaching the job is a bug here. It must not take the sweep down with it.
  test "the probe swallows an unexpected failure instead of failing the sweep" do
    Collavre::CliProxy::HealthProbe.stub(:new, ->(*) { raise "boom" }) do
      assert_nothing_raised { Collavre::GatewayHealthProbeJob.perform_now(@gateway.id) }
    end

    assert_nil @gateway.reload.health_checked_at
  end

  # A backlogged queue holds probes whose verdict has already been recorded.
  # Re-probing on those is what compounds a slow sweep into a growing backlog.
  test "the probe skips a gateway whose verdict is still fresh" do
    @gateway.update_columns(health_checked_at: 5.seconds.ago, health_status: 1)

    Collavre::CliProxy::HealthProbe.stub(:new, ->(*) { raise "must not probe" }) do
      assert_nothing_raised { Collavre::GatewayHealthProbeJob.perform_now(@gateway.id) }
    end
  end

  test "the probe runs again once the verdict has aged past the debounce" do
    @gateway.update_columns(health_checked_at: 45.seconds.ago, health_status: 1)

    Collavre::CliProxy::Client.stub(:new, FakeClient.new({ "status" => "down", "engines" => {} })) do
      Collavre::GatewayHealthProbeJob.perform_now(@gateway.id)
    end

    assert_predicate @gateway.reload, :health_down?
  end

  # The whole point of the isolation: an unreachable host holds its thread for
  # seconds, and must not hold one the mailers and broadcasts need.
  test "the probe and sweep stay off the default queue" do
    assert_equal "gateway_health", Collavre::GatewayHealthProbeJob.new.queue_name
    assert_equal "gateway_health", Collavre::GatewayHealthSweepJob.new.queue_name
    config = YAML.load(ERB.new(Rails.root.join("config/queue.yml").read).result, aliases: true)
    workers = config.fetch("production").fetch("workers")
    gateway_worker = workers.find { |w| w.fetch("queues").include?("gateway_health") }
    assert gateway_worker, "gateway_health has no worker polling it"
    assert_equal [ "gateway_health" ], gateway_worker.fetch("queues")
  end

  private

  def create_gateway
    Collavre::AgentGateway.create!(
      owner: users(:two),
      name: "Sweep proxy #{SecureRandom.hex(3)}",
      base_url: "https://proxy.example.com",
      admin_key: "admin",
      completion_key: "completion"
    )
  end
end
