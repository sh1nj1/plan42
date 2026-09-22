require "test_helper"

class Collavre::Creatives::ExpansionSaveOrderTest < ActiveSupport::TestCase
  SOURCE = "11111111-1111-4111-8111-111111111111"
  OTHER_SOURCE = "22222222-2222-4222-8222-222222222222"
  Order = Collavre::Creatives::ExpansionSaveOrder

  test "watermarks are per node rather than per browser session" do
    order = Order.new(nil)
    2_000.times do
      fence = order.issue
      assert order.accept?(fence, "branch")
    end
    assert_equal({ "branch" => 2_000 }, order.state["nodes"])
    assert_equal 2_000, order.state["issued"]
    assert_not order.accept?(1_999, "branch")
    assert_not order.accept?(2_000, "branch")
  end

  test "compaction stays bounded and retired requests cannot resurrect even after reload" do
    order = Order.new({})
    delayed = order.issue
    (Order::MAX_NODES + 5).times do |index|
      assert order.accept?(order.issue, index.to_s)
    end
    restored = Order.new(JSON.parse(order.state.to_json))
    assert_equal Order::MAX_NODES, restored.state["nodes"].size
    assert_equal 6, restored.state["floor"]
    assert_not restored.accept?(2, "0") # Evicted watermark.
    assert_not restored.accept?(delayed, "never-applied")
    assert restored.accept?(restored.issue, "0")
    assert_equal Order::MAX_NODES, restored.state["nodes"].size
    assert_operator restored.state["floor"], :>, 6
  end

  test "out of order saves to independent nodes remain valid" do
    order = Order.new({})
    first = order.issue
    second = order.issue
    assert order.accept?(second, "b")
    assert order.accept?(first, "a")
  end

  test "legacy writes are accepted only before fenced ordering starts" do
    order = Order.new(nil)
    assert order.accept?(nil, "a")
    assert_not order.accept?(1, "a")
    order.issue
    assert_not order.accept?(nil, "a")
    assert_not order.accept?("invalid", "a")
    assert_not order.accept?(0, "a")
  end
  test "intent order wins over reversed fence arrival in either apply order" do
    [ true, false ].each do |newer_first|
      order = Order.new(nil)
      newer_fence = order.issue
      older_fence = order.issue
      if newer_first
        assert order.accept?(newer_fence, "a", 200, SOURCE)
        assert_not order.accept?(older_fence, "a", 100, SOURCE)
      else
        assert order.accept?(older_fence, "a", 100, SOURCE)
        assert order.accept?(newer_fence, "a", 200, SOURCE)
      end
      order = Order.new(JSON.parse(order.state.to_json))
      assert_not order.accept?(order.issue, "a", 100, SOURCE)
      assert_not order.accept?(order.issue, "a", 200, SOURCE)
      assert order.accept?(order.issue, "legacy")
      assert order.accept?(order.issue, "a", 300, SOURCE)
      assert order.accept?(order.issue, "b", 150, SOURCE)
    end
  end

  test "invalid intent cannot consume a fence" do
    order = Order.new(nil)
    fence = order.issue
    [ 0, -1, "bad", "1.5", 9_007_199_254_740_992 ].each do |intent|
      assert_not order.accept?(fence, "a", intent, SOURCE)
    end
    assert order.accept?(fence, "a", 100, SOURCE)
  end

  test "intent watermarks remain bounded after retirement and reload" do
    order = Order.new(nil)
    (Order::MAX_NODES + 5).times do |index|
      assert order.accept?(order.issue, index.to_s, index + 1, SOURCE)
    end
    order = Order.new(JSON.parse(order.state.to_json))
    assert_equal Order::MAX_NODES, order.state["intents"]["nodes"].size
    assert_not order.accept?(1, "0", 1, SOURCE)
    assert order.accept?(order.issue, "0", 1, SOURCE)
    assert_not order.state["intents"].key?("floor")
  end
  test "different sources use fence order regardless of clock offset" do
    order = Order.new(nil)
    assert order.accept?(order.issue, "a", 8_000_000_000_000_000, SOURCE)
    old = order.issue
    assert order.accept?(order.issue, "a", 100, OTHER_SOURCE)
    assert_not order.accept?(old, "a", 8_000_000_000_000_001, SOURCE)
    assert order.accept?(order.issue, "a", 101, OTHER_SOURCE)
  end

  test "missing source or intent uses fences and clears the prior source" do
    order = Order.new(nil)
    assert order.accept?(order.issue, "a", 900, SOURCE)
    old = order.issue
    assert order.accept?(order.issue, "a", 1)
    assert_not order.accept?(old, "a", 999, SOURCE)
    assert order.accept?(order.issue, "a", nil, SOURCE)
    assert_empty order.state["intents"]["nodes"]
  end

  test "malformed sources are rejected without consuming the fence" do
    order = Order.new(nil)
    fence = order.issue
    [ "", "bad", "a" * 1_000, [], {}, 123, SOURCE + "\n" ].each do |source|
      assert_not order.accept?(fence, "a", 1, source)
    end
    assert order.accept?(fence, "a", 1, SOURCE)
  end

  test "legacy global intent floor does not poison a new source" do
    order = Order.new("issued" => 10, "floor" => 0, "nodes" => { "a" => 10 },
      "intents" => { "issued" => 999999, "floor" => 999999, "nodes" => { "a" => 999999 } })
    assert order.accept?(order.issue, "a", 1, SOURCE)
    assert_equal({ "nodes" => { "a" => { "source" => SOURCE, "intent" => 1 } } }, order.state["intents"])
  end

  test "same source reversed fences retain the greatest fence for later foreign requests" do
    order = Order.new(nil)
    first = order.issue
    second = order.issue
    assert order.accept?(second, "a", 100, SOURCE)
    assert order.accept?(first, "a", 200, SOURCE)
    assert_not order.accept?(second, "a", 999, OTHER_SOURCE)
  end
end
