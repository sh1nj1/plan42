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
