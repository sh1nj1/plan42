# frozen_string_literal: true

require "test_helper"
require Rails.root.join("engines/collavre/db/migrate/20260924060000_add_async_approval_recovery_to_comments")

class AddAsyncApprovalRecoveryToCommentsTest < ActiveSupport::TestCase
  test "backfills only persisted asynchronous decisions and ignores malformed history" do
    base = { action: "approval_gate", mode: "async", decision: { decision: "approved" } }
    decided = create_comment(base.to_json)
    native = create_comment(base.except(:mode).to_json)
    undecided = create_comment(base.except(:decision).to_json)
    malformed = create_comment("approval_gate invalid JSON")
    array = create_comment('["approval_gate"]')
    uncommitted = create_comment(base.to_json, executed_at: nil)
    migration = AddAsyncApprovalRecoveryToComments.new
    migration.stub(:add_column, nil) do
      migration.stub(:add_index, nil) { migration.up }
    end

    assert decided.reload.async_approval_recovery_pending?
    [ native, undecided, malformed, array, uncommitted ].each do |comment|
      refute comment.reload.async_approval_recovery_pending?
    end
  end

  test "recovery flag has a supporting index" do
    assert ActiveRecord::Base.connection.index_exists?(:comments, :async_approval_recovery_pending,
                                                       name: "index_comments_on_pending_async_approval")
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
