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
      Rails.cache.clear
    end

    teardown do
      travel_back
      ActiveJob::Base.queue_adapter = @previous_adapter
      Rails.cache.clear
    end

    test "enqueues matching dynamic tasks" do
      SolidQueue::RecurringTask.create!(
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
      SolidQueue::RecurringTask.create!(
        key: "cron_test_no_match",
        class_name: "Collavre::CronActionJob",
        schedule: "0 9 * * *",
        queue_name: "default",
        static: false,
        arguments: [ { creative_id: 1, topic_id: nil, agent_id: 1, message: "test" } ]
      )

      # Should only enqueue the self-rescheduling, not CronActionJob
      assert_no_enqueued_jobs(only: Collavre::CronActionJob) do
        CronSchedulerJob.perform_now
      end
    end

    test "does not enqueue same task twice in same minute" do
      SolidQueue::RecurringTask.create!(
        key: "cron_test_dedup",
        class_name: "Collavre::CronActionJob",
        schedule: "*/5 * * * *",
        queue_name: "default",
        static: false,
        arguments: [ { creative_id: 1, topic_id: nil, agent_id: 1, message: "test" } ]
      )

      CronSchedulerJob.perform_now

      # Second run in same minute should not enqueue CronActionJob again
      assert_no_enqueued_jobs(only: Collavre::CronActionJob) do
        CronSchedulerJob.perform_now
      end
    end

    test "ignores static tasks" do
      SolidQueue::RecurringTask.create!(
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
      SolidQueue::RecurringTask.create!(
        key: "cron_test_next",
        class_name: "Collavre::CronActionJob",
        schedule: "*/5 * * * *",
        queue_name: "default",
        static: false,
        arguments: [ { creative_id: 1, topic_id: nil, agent_id: 1, message: "test" } ]
      )

      CronSchedulerJob.perform_now

      travel_to @now + 5.minutes
      Rails.cache.delete(Collavre::CronSchedulerJob::RESCHEDULE_LOCK_KEY)

      assert_enqueued_with(job: Collavre::CronActionJob) do
        CronSchedulerJob.perform_now
      end
    end

    test "reschedules itself after perform" do
      assert_enqueued_with(job: Collavre::CronSchedulerJob) do
        CronSchedulerJob.perform_now
      end
    end
  end
end
