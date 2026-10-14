# frozen_string_literal: true

require "test_helper"
require Rails.root.join("engines/collavre/db/migrate/20261014000000_backfill_implicit_main_cron_topics")

module Collavre
  class BackfillImplicitMainCronTopicsTest < ActiveSupport::TestCase
    include ActiveJob::TestHelper

    test "legacy tasks older than their backfilled Main execute with an explicit topic" do
      creative = creatives(:tshirt)
      main = creative.main_topic
      task = create_task(creative)
      task.update!(created_at: main.created_at - 1.day)

      BackfillImplicitMainCronTopics.new.up
      assert_equal main.id, task.reload.arguments.first["topic_id"]
      assert_equal "legacy", task.arguments.first["message"]
      BackfillImplicitMainCronTopics.new.up
      assert_equal main.id, task.reload.arguments.first["topic_id"]

      Collavre::SystemEvents::Dispatcher.stub(:dispatch, []) do
        perform_enqueued_jobs(only: Collavre::CronActionJob) do
          assert_difference(-> { main.comments.where(content: "legacy").count }, 1) do
            Collavre::CronSchedulerJob.new.send(:dispatch_task, task)
          end
        end
      end
    end

    test "resolves linked creatives and legacy keys without changing explicit targets" do
      creative = creatives(:tshirt)
      creative.main_topic
      linked = Collavre::Creative.create!(description: "Linked cron", user: creative.user, origin: creative)
      task = create_task(linked)
      args = task.arguments.first.stringify_keys.except("creative_id")
      task.update!(arguments: [ args ])
      explicit = create_task(creative, topic_id: 999_999)
      static = create_task(creative, static: true)
      unrelated = create_task(creative, class_name: "Collavre::CronSchedulerJob")
      missing = create_task(creative, creative_id: 999_999)

      BackfillImplicitMainCronTopics.new.up

      assert_equal creative.main_topic.id, task.reload.arguments.first["topic_id"]
      assert_equal linked.id, task.arguments.first["creative_id"]
      assert_equal 999_999, explicit.reload.arguments.first.with_indifferent_access[:topic_id]
      [ static, unrelated, missing ].each { |row| assert_nil row.reload.arguments.first.with_indifferent_access[:topic_id] }
    end

    test "does not recreate a deleted Main or modify malformed arguments" do
      creative = creatives(:tshirt)
      creative.main_topic.destroy!
      task = create_task(creative)
      malformed = create_task(creative)
      malformed.update!(arguments: [])
      assert_no_difference("Collavre::Topic.count") { BackfillImplicitMainCronTopics.new.up }
      assert_nil task.reload.arguments.first["topic_id"]
      assert_equal [], malformed.reload.arguments
      BackfillImplicitMainCronTopics.new.down
    end

    test "fresh installations without queue tables require no backfill" do
      SolidQueue::RecurringTask.stub(:table_exists?, false) do
        assert_nil BackfillImplicitMainCronTopics.new.up
      end
    end

    private

    def create_task(creative, topic_id: nil, static: false, class_name: "Collavre::CronActionJob", creative_id: creative.id)
      SolidQueue::RecurringTask.create!(
        key: "cron_#{creative.id}_#{SecureRandom.hex(4)}", class_name: class_name,
        schedule: "* * * * *", static: static,
        arguments: [ { creative_id: creative_id, topic_id: topic_id,
                       agent_id: users(:ai_bot).id, message: "legacy" } ]
      )
    end
  end
end
