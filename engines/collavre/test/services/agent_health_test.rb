# frozen_string_literal: true

require "test_helper"

module Collavre
  class AgentHealthTest < ActiveSupport::TestCase
    class Checker
      def initialize(agent:); end
    end

    teardown { AgentHealth.unregister("test-vendor") }

    test "registers and resolves checkers by normalized vendor" do
      AgentHealth.register(" Test-Vendor ", Checker)

      assert_equal Checker, AgentHealth.checker_for("TEST-VENDOR")
      assert_includes AgentHealth.vendors, "test-vendor"
    end

    test "unregisters a checker without affecting unknown vendors" do
      AgentHealth.register("test-vendor", Checker)

      assert_equal Checker, AgentHealth.unregister("TEST-VENDOR")
      assert_nil AgentHealth.checker_for("test-vendor")
      assert_nil AgentHealth.unregister("missing-vendor")
    end

    test "rejects an empty vendor and a non-instantiable checker" do
      assert_raises(ArgumentError) { AgentHealth.register(" ", Checker) }
      assert_raises(ArgumentError) { AgentHealth.register("test-vendor", Object.new) }
    end
  end
end
