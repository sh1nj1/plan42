# frozen_string_literal: true

require "test_helper"

module Collavre
  module Crons
    class RecurringTaskIndexTest < ActiveSupport::TestCase
      setup do
        @tasks = []
        @creative = creatives(:tshirt)
      end

      teardown do
        @tasks.each { |task| task.destroy! if task.persisted? }
      end

      test "groups cron tasks by creative id in key order" do
        later_key = "cron_#{@creative.id}_z_#{SecureRandom.hex(4)}"
        earlier_key = "cron_#{@creative.id}_a_#{SecureRandom.hex(4)}"
        create_task(key: later_key)
        create_task(key: earlier_key)
        create_task(key: "other_#{@creative.id}_#{SecureRandom.hex(4)}")

        index = RecurringTaskIndex.new

        assert_includes index.creative_ids, @creative.id
        assert_equal [ earlier_key, later_key ], index.tasks_for(@creative.id).map(&:key)
        assert_empty index.tasks_for(-1)
      end

      test "ignores static cron tasks" do
        create_task(key: "cron_#{@creative.id}_#{SecureRandom.hex(4)}", static: true)

        assert_empty RecurringTaskIndex.new.creative_ids
      end

      test "groups a linked creative cron under its effective origin" do
        linked = Creative.create!(user: users(:two), origin: @creative)
        task = create_task(key: "cron_#{linked.id}_#{SecureRandom.hex(4)}")

        index = RecurringTaskIndex.new

        assert_includes index.creative_ids, @creative.id
        refute_includes index.creative_ids, linked.id
        assert_equal [ task.key ], index.tasks_for(@creative.id).map(&:key)
        assert_empty index.tasks_for(linked.id)
      end

      test "groups cron tasks by topic and treats a missing topic as Main" do
        main_topic = @creative.main_topic(fallback_user: users(:one))
        other_topic = @creative.topics.create!(name: "Scheduled topic", user: users(:one))
        main_task = create_task(
          key: "cron_#{@creative.id}_main_#{SecureRandom.hex(4)}",
          arguments: [ { creative_id: @creative.id } ]
        )
        other_task = create_task(
          key: "cron_#{@creative.id}_topic_#{SecureRandom.hex(4)}",
          arguments: [ { creative_id: @creative.id, topic_id: other_topic.id } ]
        )

        index = RecurringTaskIndex.new

        assert_equal [ main_task.key ], index.tasks_for_topic(
          @creative.id,
          main_topic.id,
          main_topic_id: main_topic.id
        ).map(&:key)
        assert_equal [ other_task.key ], index.tasks_for_topic(
          @creative.id,
          other_topic.id,
          main_topic_id: main_topic.id
        ).map(&:key)
      end

      private

      def create_task(key:, static: false, arguments: [])
        task = SolidQueue::RecurringTask.create!(
          key: key,
          class_name: "Collavre::CronActionJob",
          schedule: "0 9 * * *",
          static: static,
          arguments: arguments
        )
        @tasks << task
        task
      end
    end
  end
end
