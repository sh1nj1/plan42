require "test_helper"
require "eventmachine"

module CollavreOpenclaw
  class EmReactorTest < ActiveSupport::TestCase
    teardown do
      EmReactor.stop! if EmReactor.running?
    end

    test "starts reactor in background thread" do
      EmReactor.ensure_running!
      assert EmReactor.running?
    end

    test "ensure_running is idempotent" do
      EmReactor.ensure_running!
      EmReactor.ensure_running!
      assert EmReactor.running?
    end

    test "stop shuts down reactor" do
      EmReactor.ensure_running!
      assert EmReactor.running?

      EmReactor.stop!
      # Give it a moment to shut down
      sleep 0.1
      refute EmReactor.running?
    end

    test "next_tick schedules work in reactor" do
      result = Queue.new

      EmReactor.next_tick do
        result.push(Thread.current.name)
      end

      thread_name = result.pop
      assert_equal "openclaw-em-reactor", thread_name
    end
  end
end
