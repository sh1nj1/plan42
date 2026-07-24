require "test_helper"

module Collavre
  class AgentSessionAbortTest < ActiveSupport::TestCase
    teardown do
      AgentSessionAbort.registry.delete("test-vendor")
    end

    test "dispatches to the handler registered for the agent's vendor (case-insensitive)" do
      received = nil
      AgentSessionAbort.register("test-vendor", lambda { |agent:, task:, creative:, comment:|
        received = { agent: agent, task: task, creative: creative, comment: comment }
      })
      agent = Struct.new(:llm_vendor).new("Test-Vendor")
      task = Object.new

      AgentSessionAbort.call(agent: agent, task: task, creative: :c, comment: :cm)

      assert_equal({ agent: agent, task: task, creative: :c, comment: :cm }, received)
    end

    test "is a no-op when no handler is registered for the vendor" do
      agent = Struct.new(:llm_vendor).new("unknown-vendor")
      assert_nil AgentSessionAbort.call(agent: agent, task: Object.new)
    end

    test "is a no-op for a nil agent or blank vendor" do
      assert_nil AgentSessionAbort.call(agent: nil, task: Object.new)
      blank = Struct.new(:llm_vendor).new(nil)
      assert_nil AgentSessionAbort.call(agent: blank, task: Object.new)
    end

    test "swallows handler errors so a failed abort never breaks task cancellation" do
      AgentSessionAbort.register("test-vendor", ->(**) { raise "boom" })
      agent = Struct.new(:llm_vendor).new("test-vendor")
      assert_nothing_raised do
        AgentSessionAbort.call(agent: agent, task: Object.new)
      end
    end
  end
end
