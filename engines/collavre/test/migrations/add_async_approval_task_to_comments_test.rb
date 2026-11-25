# frozen_string_literal: true

require "test_helper"
require Rails.root.join("engines/collavre/db/migrate/20260924070000_add_async_approval_task_to_comments")

class AddAsyncApprovalTaskToCommentsTest < ActiveSupport::TestCase
  test "backfills asynchronous origins and ignores malformed history" do
    base = { action: "approval_gate", mode: "async", task_id: 123, decision: { decision: "approved" } }
    decided = create_comment(base.to_json)
    native = create_comment(base.except(:mode).to_json)
    undecided = create_comment(base.except(:decision).to_json)
    malformed = create_comment("approval_gate invalid JSON")
    array = create_comment('["approval_gate"]')
    uncommitted = create_comment(base.to_json, executed_at: nil)
    migration = AddAsyncApprovalTaskToComments.new
    migration.stub(:add_column, nil) do
      migration.stub(:add_index, nil) { migration.up }
    end

    assert_equal 123, decided.reload.async_approval_task_id
    assert_equal 123, undecided.reload.async_approval_task_id
    assert_equal 123, uncommitted.reload.async_approval_task_id
    [ native, malformed, array ].each do |comment|
      assert_nil comment.reload.async_approval_task_id
    end
  end

  test "origin task has a supporting index" do
    assert ActiveRecord::Base.connection.index_exists?(:comments, :async_approval_task_id,
                                                       name: "index_comments_on_async_approval_task_id")
  end

  private

  def create_comment(action, executed_at: Time.current)
    comment = Collavre::Comment.create!(creative: Collavre::Creative.create!(description: "History", user: users(:one)),
                                        user: users(:one),
                                        content: "Historical gate", skip_dispatch: true)
    comment.update_columns(action: action, action_executed_at: executed_at)
    comment
  end
end
