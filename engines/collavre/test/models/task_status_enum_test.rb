require "test_helper"

module Collavre
  class TaskStatusEnumTest < ActiveSupport::TestCase
    setup do
      @owner = users(:one)
      @agent = User.create!(email: "agent-enum@example.com", password: TEST_PASSWORD, name: "Agent")
    end

    test "status is a string-backed enum covering all nine values" do
      assert_equal(
        %w[pending queued running delegated pending_approval done failed cancelled escalated].sort,
        Collavre::Task.statuses.keys.sort
      )
      # string-backed: key maps to identical string
      Collavre::Task.statuses.each { |k, v| assert_equal k, v }
    end

    test "predicates and default" do
      task = Task.create!(name: "T", agent: @agent)
      assert task.pending?
      task.running!
      assert task.running?
      assert_equal "running", task.reload.status
    end

    test "existing scopes still resolve via string values" do
      task = Task.create!(name: "T", status: "queued", topic_id: 123, agent: @agent)
      assert_includes Task.queued_for_topic(123), task
      assert_includes Task.occupying_topic_slot(123), Task.create!(name: "R", status: "running", topic_id: 123, agent: @agent)
    end

    test "update_all bypasses callbacks and keeps the string value" do
      task = Task.create!(name: "T", status: "delegated", agent: @agent)
      Task.where(id: task.id).update_all(status: "done")
      assert task.reload.done?
    end
  end
end
