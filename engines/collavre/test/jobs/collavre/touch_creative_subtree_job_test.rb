# frozen_string_literal: true

require "test_helper"

module Collavre
  class TouchCreativeSubtreeJobTest < ActiveSupport::TestCase
    include ActiveJob::TestHelper

    setup do
      @original_queue_adapter = ActiveJob::Base.queue_adapter
      ActiveJob::Base.queue_adapter = :test
      @owner = users(:one)
      @root = Creative.create!(user: @owner, description: "Root")
      @child = Creative.create!(user: @owner, parent: @root, description: "Child")
      @grandchild = Creative.create!(user: @owner, parent: @child, description: "Grandchild")
      @new_parent = Creative.create!(user: @owner, description: "New parent")
      clear_enqueued_jobs
    end

    teardown do
      ActiveJob::Base.queue_adapter = @original_queue_adapter
    end

    test "moving a creative enqueues subtree touching after commit" do
      old_timestamp = 2.days.ago.change(usec: 0)
      Creative.where(id: [ @child.id, @grandchild.id ]).update_all(updated_at: old_timestamp)

      assert_enqueued_with(job: TouchCreativeSubtreeJob, args: [ @root.id ]) do
        @root.update!(parent: @new_parent)
      end

      assert_equal old_timestamp, @child.reload.updated_at
      assert_equal old_timestamp, @grandchild.reload.updated_at
    end

    test "touches all current descendants in one update" do
      old_timestamp = 2.days.ago.change(usec: 0)
      Creative.where(id: [ @child.id, @grandchild.id ]).update_all(updated_at: old_timestamp)
      updates = []
      subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |_name, _start, _finish, _id, payload|
        sql = payload[:sql]
        updates << sql if sql.match?(/UPDATE .*creatives.* SET .*updated_at/i)
      end

      TouchCreativeSubtreeJob.perform_now(@root.id)

      assert_operator @child.reload.updated_at, :>, old_timestamp
      assert_operator @grandchild.reload.updated_at, :>, old_timestamp
      assert_equal 1, updates.size
    ensure
      ActiveSupport::Notifications.unsubscribe(subscriber) if subscriber
    end

    test "is a no-op when the creative was deleted" do
      @root.destroy!

      assert_nothing_raised do
        TouchCreativeSubtreeJob.perform_now(@root.id)
      end
    end
  end
end
