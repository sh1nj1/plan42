require "test_helper"

class Collavre::Creatives::ExpansionSaveOrderTest < ActiveSupport::TestCase
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
        assert order.accept?(newer_fence, "a", 200)
        assert_not order.accept?(older_fence, "a", 100)
      else
        assert order.accept?(older_fence, "a", 100)
        assert order.accept?(newer_fence, "a", 200)
      end
      order = Order.new(JSON.parse(order.state.to_json))
      assert_not order.accept?(order.issue, "a", 100)
      assert_not order.accept?(order.issue, "a", 200)
      assert_not order.accept?(order.issue, "a")
      assert order.accept?(order.issue, "a", 300)
      assert order.accept?(order.issue, "b", 150)
    end
  end

  test "invalid intent cannot consume a fence" do
    order = Order.new(nil)
    fence = order.issue
    [ 0, -1, "bad", "1.5", 9_007_199_254_740_992 ].each do |intent|
      assert_not order.accept?(fence, "a", intent)
    end
    assert order.accept?(fence, "a", 100)
  end

  test "intent watermarks remain bounded after retirement and reload" do
    order = Order.new(nil)
    (Order::MAX_NODES + 5).times do |index|
      assert order.accept?(order.issue, index.to_s, index + 1)
    end
    order = Order.new(JSON.parse(order.state.to_json))
    assert_equal Order::MAX_NODES, order.state["intents"]["nodes"].size
    assert_not order.accept?(order.issue, "0", 1)
  end
end
