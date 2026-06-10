require "test_helper"

module CollavreOpenclaw
  class SessionAbortServiceTest < ActiveSupport::TestCase
    setup do
      @user = User.create!(email: "agent-abort@example.com", password: "password123", name: "Abort Bot")
      @creative = Collavre::Creative.create!(description: "Abort Creative", user: @user)
      @task = Collavre::Task.create!(name: "abort-task", agent: @user, creative: @creative, status: "running")
    end

    teardown do
      @task&.destroy
      @creative&.destroy
      @user&.destroy
    end

    test "registered as the openclaw handler on the core seam" do
      assert_equal SessionAbortService, Collavre::AgentSessionAbort.registry["openclaw"]
    end

    test "aborts the gateway session via the agent's connection using the adapter session key" do
      conn = Minitest::Mock.new
      conn.expect(:chat_abort, nil) do |session_key:|
        session_key.include?("collavre:#{@user.id}")
      end

      manager = Object.new
      manager.define_singleton_method(:connection_for) { |_agent| conn }

      ConnectionManager.stub(:instance, manager) do
        SessionAbortService.call(agent: @user, task: @task, creative: @creative)
      end

      assert conn.verify
    end
  end
end
