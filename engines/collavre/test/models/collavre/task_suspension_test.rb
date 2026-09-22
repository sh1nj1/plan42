# frozen_string_literal: true

require "test_helper"

module Collavre
  class TaskSuspensionTest < ActiveSupport::TestCase
    setup do
      @agent = users(:ai_bot)
      @comment_id = 4242
    end

    def task(status:, **attributes)
      Task.create!(name: "Turn", status: status, agent: @agent, trigger_event_name: "comment_created",
                   trigger_event_payload: { "comment" => { "id" => @comment_id } }, **attributes)
    end

    test "a suspended turn is active work that Stop can end" do
      suspended = task(status: "suspended")

      assert suspended.active?
      assert_equal "suspended", suspended.cancel_if_active!
      assert_equal "cancelled", suspended.reload.status
    end

    test "a suspended turn does not occupy its topic slot" do
      suspended = task(status: "suspended", topic_id: 77)
      assert_not_includes Task.occupying_topic_slot(77), suspended
    end

    test "a suspended turn still counts as answering its comment" do
      task(status: "suspended")
      assert Task.duplicate_running_for_comment?(@agent.id, @comment_id)
    end

    test "awaiting_reply covers delegated turns, including ones suspended while delegated" do
      delegated = task(status: "delegated")
      offline = task(status: "suspended", suspended_from: "delegated")
      restarted = task(status: "suspended", suspended_from: "running")

      awaiting = Task.awaiting_reply
      assert_includes awaiting, delegated
      assert_includes awaiting, offline
      assert_not_includes awaiting, restarted
    end
  end
end
