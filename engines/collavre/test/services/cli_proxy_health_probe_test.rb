require "test_helper"

class CliProxyHealthProbeTest < ActiveSupport::TestCase
  class FakeClient
    attr_reader :calls

    def initialize(ready:, live: { "status" => "ok", "provider" => "claude-code-cli" }, on_ready: nil)
      @ready = ready
      @live = live
      @on_ready = on_ready
      @calls = []
    end

    def health_ready
      @calls << :health_ready
      @on_ready&.call
      @ready.is_a?(Exception) ? raise(@ready) : @ready
    end

    def health_live
      @calls << :health_live
      @live.is_a?(Exception) ? raise(@live) : @live
    end
  end

  setup do
    @gateway = Collavre::AgentGateway.create!(
      owner: users(:two),
      name: "Probe proxy #{SecureRandom.hex(3)}",
      base_url: "https://proxy.example.com",
      admin_key: "admin",
      completion_key: "completion"
    )
  end

  test "records the rollup and the per-engine detail" do
    engines = { "mode" => "host", "items" => { "codex" => { "state" => "authenticated" } } }
    probe(ready: { "status" => "degraded", "engines" => engines })

    @gateway.reload
    assert_predicate @gateway, :health_degraded?
    assert_equal engines, @gateway.health_engines
    assert_nil @gateway.health_error
    assert_in_delta Time.current, @gateway.health_checked_at, 5
  end

  test "bounds the complete health request by the open and read timeout budget" do
    probe = Collavre::CliProxy::HealthProbe.new(gateway: @gateway)
    client = probe.instance_variable_get(:@client)
    http_client = client.instance_variable_get(:@http_client)

    assert_equal Collavre::CliProxy::HealthProbe::REQUEST_TIMEOUT,
                 http_client.instance_variable_get(:@request_timeout)
  end

  test "persists only bounded engine state fields" do
    items = (Collavre::CliProxy::HealthProbe::ENGINE_LIMIT + 5).times.to_h do |index|
      [ "engine_#{index}", { "state" => "authenticated", "detail" => "x" * 1_000 } ]
    end
    probe(ready: {
      "status" => "ok",
      "engines" => { "mode" => "host", "items" => items, "ignored" => "x" * 1_000 }
    })

    engines = @gateway.reload.health_engines
    assert_equal %w[items mode], engines.keys.sort
    assert_equal Collavre::CliProxy::HealthProbe::ENGINE_LIMIT, engines.fetch("items").size
    assert_equal({ "state" => "authenticated" }, engines.dig("items", "engine_0"))
  end

  test "records down when every engine is logged out" do
    probe(ready: { "status" => "down", "engines" => { "ready" => 0, "total" => 2 } })

    assert_predicate @gateway.reload, :health_down?
    assert_not @gateway.health_serves_engine?("codex")
  end

  test "a transport failure is a verdict, not an exception" do
    error = Collavre::CliProxy::Client::Error.new("connection refused", code: "proxy_unreachable")
    probe(ready: error)

    @gateway.reload
    assert_predicate @gateway, :health_unreachable?
    assert_equal "connection refused", @gateway.health_error
    assert_empty @gateway.health_engines
  end

  test "a body this Collavre has no name for is not read as ok" do
    probe(ready: { "status" => "brand-new-rollup" })

    assert_predicate @gateway.reload, :health_unknown?
    assert_not @gateway.health_reachable?
  end

  # A proxy older than the liveness/readiness split has no /health/ready. Reading
  # that 404 as unreachable would take every agent on an entirely healthy older
  # gateway offline the moment this feature ships.
  test "falls back to liveness when the readiness route does not exist" do
    client = FakeClient.new(ready: Collavre::CliProxy::Client::Error.new("Not Found", status: 404))
    Collavre::CliProxy::HealthProbe.new(gateway: @gateway, client: client).call

    assert_equal %i[health_ready health_live], client.calls
    @gateway.reload
    assert_predicate @gateway, :health_degraded?
    assert_match(/liveness only/, @gateway.health_error)
    assert @gateway.health_serves_engine?("claude"), "an older gateway that answers still serves"
  end

  test "an older proxy that does not answer at all is unreachable" do
    client = FakeClient.new(
      ready: Collavre::CliProxy::Client::Error.new("Not Found", status: 404),
      live: Collavre::CliProxy::Client::Error.new("connection refused")
    )
    Collavre::CliProxy::HealthProbe.new(gateway: @gateway, client: client).call

    assert_predicate @gateway.reload, :health_unreachable?
  end

  test "does not accept an unrelated successful legacy health response" do
    client = FakeClient.new(
      ready: Collavre::CliProxy::Client::Error.new("Not Found", status: 404),
      live: { "status" => "ok" }
    )
    Collavre::CliProxy::HealthProbe.new(gateway: @gateway, client: client).call

    @gateway.reload
    assert_predicate @gateway, :health_unreachable?
    assert_equal "Invalid liveness response from CLI proxy", @gateway.health_error
  end

  test "discards a verdict when the gateway configuration changes during the probe" do
    @gateway.update_columns(health_status: 1, health_checked_at: Time.current)
    client = FakeClient.new(
      ready: { "status" => "ok", "engines" => {} },
      on_ready: -> { @gateway.update!(base_url: "https://replacement.example.com") }
    )

    Collavre::CliProxy::HealthProbe.new(gateway: @gateway, client: client).call

    @gateway.reload
    assert_predicate @gateway, :health_unknown?
    assert_nil @gateway.health_checked_at
  end

  test "recording a verdict does not touch the row a user edits" do
    updated_at = @gateway.updated_at
    probe(ready: { "status" => "ok", "engines" => { "mode" => "host", "items" => {} } })

    assert_equal updated_at.to_i, @gateway.reload.updated_at.to_i
  end

  test "truncates an error too long for the column" do
    probe(ready: Collavre::CliProxy::Client::Error.new("x" * 500))

    assert_equal Collavre::CliProxy::HealthProbe::ERROR_LIMIT, @gateway.reload.health_error.length
  end

  private

  def probe(ready:)
    Collavre::CliProxy::HealthProbe.new(gateway: @gateway, client: FakeClient.new(ready: ready)).call
  end
end
