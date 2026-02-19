# frozen_string_literal: true

require "test_helper"

module Collavre
  class CronSchedulerJobTest < ActiveSupport::TestCase
    include ActiveJob::TestHelper

    setup do
      @now = Time.zone.parse("2026-02-20 10:05:00")
      travel_to @now
      @previous_adapter = ActiveJob::Base.queue_adapter
      ActiveJob::Base.queue_adapter = :test
    end

    teardown do
      travel_back
      ActiveJob::Base.queue_adapter = @previous_adapter
    end

    test "enqueues matching dynamic tasks" do
      task = SolidQueue::RecurringTask.create!(
        key: "cron_test_abc",
        class_name: "Collavre::CronActionJob",
        schedule: "*/5 * * * *",
        queue_name: "default",
        static: false,
        arguments: [ { creative_id: 1, topic_id: nil, agent_id: 1, message: "test" } ]
      )

      assert_enqueued_with(job: Collavre::CronActionJob) do
        CronSchedulerJob.perform_now
      end
    end

    test "skips tasks that do not match current time" do
      task = SolidQueue::RecurringTask.create!(
        key: "cron_test_no_match",
        class_name: "Collavre::CronActionJob",
        schedule: "0 9 * * *", # 9am only
        queue_name: "default",
        static: false,
        arguments: [ { creative_id: 1, topic_id: nil, agent_id: 1, message: "test" } ]
      )

      assert_no_enqueued_jobs(only: Collavre::CronActionJob) do
        CronSchedulerJob.perform_now
      end
    end

    test "does not enqueue same task twice in same minute" do
      task = SolidQueue::RecurringTask.create!(
        key: "cron_test_dedup",
        class_name: "Collavre::CronActionJob",
        schedule: "*/5 * * * *",
        queue_name: "default",
        static: false,
        arguments: [ { creative_id: 1, topic_id: nil, agent_id: 1, message: "test" } ]
      )

      CronSchedulerJob.perform_now

      # Second run in same minute should not enqueue again
      assert_no_enqueued_jobs(only: Collavre::CronActionJob) do
        CronSchedulerJob.perform_now
      end
    end

    test "ignores static tasks" do
      task = SolidQueue::RecurringTask.create!(
        key: "cron_test_static",
        class_name: "Collavre::CronActionJob",
        schedule: "*/5 * * * *",
        queue_name: "default",
        static: true,
        arguments: [ { creative_id: 1, topic_id: nil, agent_id: 1, message: "test" } ]
      )

      assert_no_enqueued_jobs(only: Collavre::CronActionJob) do
        CronSchedulerJob.perform_now
      end
    end

    test "enqueues task again in next matching minute" do
      task = SolidQueue::RecurringTask.create!(
        key: "cron_test_next",
        class_name: "Collavre::CronActionJob",
        schedule: "*/5 * * * *",
        queue_name: "default",
        static: false,
        arguments: [ { creative_id: 1, topic_id: nil, agent_id: 1, message: "test" } ]
      )

      CronSchedulerJob.perform_now

      # Advance to next matching minute
      travel_to @now + 5.minutes

      assert_enqueued_with(job: Collavre::CronActionJob) do
        CronSchedulerJob.perform_now
      end
    end
  end
end
