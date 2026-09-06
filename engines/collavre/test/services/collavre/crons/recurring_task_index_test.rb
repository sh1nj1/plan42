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

      test "scopes a creative family index to the origin and its linked creatives" do
        linked = Creative.create!(user: users(:two), origin: @creative)
        unrelated = creatives(:root_parent)
        origin_task = create_task(key: "cron_#{@creative.id}_#{SecureRandom.hex(4)}")
        linked_task = create_task(key: "cron_#{linked.id}_#{SecureRandom.hex(4)}")
        create_task(key: "cron_#{unrelated.id}_#{SecureRandom.hex(4)}")

        index = RecurringTaskIndex.for_creative_family(@creative)

        assert_equal [ @creative.id ], index.creative_ids
        assert_equal [ origin_task.key, linked_task.key ].sort, index.tasks_for(@creative.id).map(&:key)
      end

      test "scopes details for multiple visible creative families" do
        other = creatives(:root_parent)
        unrelated = Creative.create!(user: @creative.user, description: "Unrelated")
        included_task = create_task(key: "cron_#{@creative.id}_#{SecureRandom.hex(4)}")
        other_task = create_task(key: "cron_#{other.id}_#{SecureRandom.hex(4)}")
        create_task(key: "cron_#{unrelated.id}_#{SecureRandom.hex(4)}")

        index = RecurringTaskIndex.for_creatives([ @creative, other ])

        assert_equal [ included_task.key ], index.tasks_for(@creative.id).map(&:key)
        assert_equal [ other_task.key ], index.tasks_for(other.id).map(&:key)
      end

      test "returns an empty index for no visible creatives" do
        index = RecurringTaskIndex.for_creatives([])

        assert_empty index.creative_ids
        assert_empty index.tasks_for(@creative.id)
      end

      test "loads only keys for creative id filtering and defers task details" do
        create_task(
          key: "cron_#{@creative.id}_#{SecureRandom.hex(4)}",
          arguments: [ { message: "large payload" } ]
        )
        queries = []
        subscriber = lambda do |_name, _started, _finished, _unique_id, payload|
          queries << payload[:sql] if payload[:sql].include?("solid_queue_recurring_tasks")
        end
        index = RecurringTaskIndex.new

        ActiveSupport::Notifications.subscribed(subscriber, "sql.active_record") do
          assert_includes index.creative_ids, @creative.id
        end

        assert queries.any?
        assert queries.none? { |sql| sql.include?("arguments") }
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
