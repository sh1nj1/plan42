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

  test "the sweep enqueues one probe per active gateway assigned to a CLI proxy agent" do
    assign_gateway
    assign_gateway
    unassigned = create_gateway
    inactive = create_gateway
    assign_gateway(inactive)
    inactive.update_columns(active: false)

    probed = []
    Collavre::GatewayHealthProbeJob.stub(:perform_later, ->(id) { probed << id }) do
      Collavre::GatewayHealthSweepJob.perform_now
    end

    assert_equal 1, probed.count(@gateway.id)
    assert_not_includes probed, unassigned.id
    assert_not_includes probed, inactive.id
  end

  test "the probe records a verdict for the gateway it names" do
    assign_gateway
    body = { "status" => "ok", "engines" => { "ready" => 1, "total" => 1 } }
    Collavre::CliProxy::Client.stub(:new, FakeClient.new(body)) do
      Collavre::GatewayHealthProbeJob.perform_now(@gateway.id)
    end

    assert_predicate @gateway.reload, :health_ok?
  end

  # A row deactivated, unassigned, or deleted between the sweep and the probe
  # must not be probed: the sweep's snapshot is already stale when it runs.
  test "the probe skips a gateway that is gone, deactivated, or unassigned" do
    assigned = create_gateway
    assign_gateway(assigned)
    assigned.update_columns(active: false)

    Collavre::GatewayHealthProbeJob.perform_now(assigned.id)
    Collavre::GatewayHealthProbeJob.perform_now(@gateway.id)
    Collavre::GatewayHealthProbeJob.perform_now(-1)

    assert_nil assigned.reload.health_checked_at
    assert_nil @gateway.reload.health_checked_at
  end

  # The probe turns every transport failure into a recorded verdict, so anything
  # reaching the job is a bug here. It must not take the sweep down with it.
  test "the probe swallows an unexpected failure instead of failing the sweep" do
    assign_gateway
    Collavre::CliProxy::HealthProbe.stub(:new, ->(*) { raise "boom" }) do
      assert_nothing_raised { Collavre::GatewayHealthProbeJob.perform_now(@gateway.id) }
    end

    assert_nil @gateway.reload.health_checked_at
  end

  test "the probe coalesces ready and running copies per gateway" do
    first = Collavre::GatewayHealthProbeJob.new(@gateway.id)
    duplicate = Collavre::GatewayHealthProbeJob.new(@gateway.id)
    other = Collavre::GatewayHealthProbeJob.new(create_gateway.id)
    records = [ first, duplicate, other ].map { |job| SolidQueue::Job.enqueue(job) }

    assert_predicate records.first, :persisted?
    assert_not_predicate records.second, :persisted?
    assert_predicate records.third, :persisted?
    assert_equal 1, first.concurrency_limit
    assert_equal 1.day, first.concurrency_duration
    assert_equal :discard, first.class.concurrency_on_conflict
  end

  test "the recurring sweep coalesces while an earlier sweep is pending" do
    first = Collavre::GatewayHealthSweepJob.new
    duplicate = Collavre::GatewayHealthSweepJob.new
    records = [ first, duplicate ].map { |job| SolidQueue::Job.enqueue(job) }

    assert_predicate records.first, :persisted?
    assert_not_predicate records.second, :persisted?
    assert_equal 1, first.concurrency_limit
    assert_equal 1.day, first.concurrency_duration
    assert_equal :discard, first.class.concurrency_on_conflict
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
    assert_equal 12, gateway_worker.fetch("threads")
  end

  private

  def create_gateway
    Collavre::AgentGateway.create!(
      owner: users(:two),
      name: "Sweep proxy #{SecureRandom.hex(3)}",
      base_url: "https://proxy.example.com",
      admin_key: "admin",
      completion_key: "completion",
      identity_secret: "i" * 32
    )
  end

  def assign_gateway(gateway = @gateway)
    Collavre::User.create!(
      name: "Sweep agent #{SecureRandom.hex(3)}",
      email: "sweep-agent-#{SecureRandom.hex(6)}@ai.local",
      password: SecureRandom.hex(24),
      system_prompt: "Help",
      llm_vendor: "cli_proxy",
      llm_model: "paperclip/codex_local",
      created_by_id: gateway.owner_id,
      agent_gateway: gateway
    )
  end
end
