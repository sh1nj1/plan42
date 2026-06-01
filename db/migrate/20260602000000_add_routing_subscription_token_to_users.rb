# frozen_string_literal: true

# Cross-process ownership marker for the per-agent ActionCable subscription.
# The previous per-process Concurrent::Map could not distinguish a stale
# unsubscribe on process A from a live subscribe on process B in scaled
# Puma/Kamal deployments (WEB_CONCURRENCY > 1, Solid Cable). Storing the
# active subscription token alongside routing_expression on the same row
# means the unsubscribe path can do a single atomic UPDATE filtered on the
# token value; a stale unsubscribe whose token has been overwritten by a
# newer subscribe matches zero rows and is a no-op across processes.
class AddRoutingSubscriptionTokenToUsers < ActiveRecord::Migration[8.1]
  def change
    add_column :users, :routing_subscription_token, :string
  end
end
