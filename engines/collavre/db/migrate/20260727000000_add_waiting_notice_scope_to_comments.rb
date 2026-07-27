# Record what a "⏳ waiting on the topic slot" notice speaks for, instead of
# inferring it from whichever sibling notices happen to still stand.
#
# A topic gets one deduplicated notice while coalescing is on and one notice per
# deferral while it is off, so the two kinds coexist whenever the policy changes
# mid-wait or differs per agent. Reading "no sibling notice left" as "this one
# stood for the whole topic" then inverts ownership: deleting the shared notice
# is classified as deleting a per-deferral one and cancels the newest queued
# waiter — which may be the one the *other* notice speaks for.
#
# Nullable with no backfill on purpose: a notice already on screen was posted by
# the pre-existing code and there is nothing on the row to say which kind it was.
# Comment#cancel_queued_tasks_for_waiting_notice keeps its old behaviour for
# those, so an in-flight wait is neither widened nor silently disarmed.
class AddWaitingNoticeScopeToComments < ActiveRecord::Migration[8.1]
  def up
    unless column_exists?(:comments, :waiting_notice_scope)
      add_column :comments, :waiting_notice_scope, :string
    end

    unless column_exists?(:comments, :waiting_notice_task_id)
      add_column :comments, :waiting_notice_task_id, :integer
    end
  end

  def down
    remove_column :comments, :waiting_notice_task_id if column_exists?(:comments, :waiting_notice_task_id)
    remove_column :comments, :waiting_notice_scope if column_exists?(:comments, :waiting_notice_scope)
  end
end
