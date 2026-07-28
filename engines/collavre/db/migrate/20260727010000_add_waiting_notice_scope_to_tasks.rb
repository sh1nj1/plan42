# Record which kind of "⏳ waiting" notice speaks for a waiter on the waiter
# itself, at the moment it is parked.
#
# The waiter and its notice commit in two steps, so asking the notices which
# waiters they own has a window where the answer is wrong: an opted-out waiter is
# already queued while its own notice does not exist yet, and a shared notice
# deleted in that window reads it as one of its own and cancels it. What speaks
# for a waiter is decided by the agent's coalescing policy when the row is
# created, not by which neighbouring rows happen to be visible later.
#
# Nullable with no backfill on purpose: a waiter parked by the pre-existing code
# says nothing about which notice spoke for it, and
# Comment#represented_queued_waiters keeps the old sibling-notice answer for
# those rows. Widening would discard work; narrowing would leave an in-flight
# wait with no stop control.
class AddWaitingNoticeScopeToTasks < ActiveRecord::Migration[8.1]
  def up
    return if column_exists?(:tasks, :waiting_notice_scope)

    add_column :tasks, :waiting_notice_scope, :string
  end

  def down
    remove_column :tasks, :waiting_notice_scope if column_exists?(:tasks, :waiting_notice_scope)
  end
end
