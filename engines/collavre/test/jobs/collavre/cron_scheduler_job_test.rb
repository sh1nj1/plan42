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

      assert_enqueued_with(job: Collavre::CronActionJob) do
        CronSchedulerJob.perform_now
      end
    end

    test "removes a run-once task after its first enqueue" do
      creative = creatives(:tshirt)
      task = SolidQueue::RecurringTask.create!(
        key: "cron_test_once",
        class_name: "Collavre::CronActionJob",
        schedule: "*/5 * * * *",
        queue_name: "default",
        static: false,
        arguments: [ { creative_id: creative.id, topic_id: nil, agent_id: 1, message: "test", once: true } ]
      )

      changed_creative = nil
      Crons::ChangeBroadcaster.stub(:call, ->(value) { changed_creative = value }) do
        assert_enqueued_with(
          job: Collavre::CronActionJob,
          args: [ { creative_id: creative.id, topic_id: nil, agent_id: 1, message: "test" } ]
        ) do
          CronSchedulerJob.perform_now
        end
      end

      assert_not SolidQueue::RecurringTask.exists?(task.id)
      assert_equal creative, changed_creative
    end

    test "keeps a run-once task when enqueueing fails" do
      task = SolidQueue::RecurringTask.create!(
        key: "cron_test_once_retry",
        class_name: "Collavre::CronActionJob",
        schedule: "*/5 * * * *",
        queue_name: "default",
        static: false,
        arguments: [ { creative_id: 1, topic_id: nil, agent_id: 1, message: "test", once: true } ]
      )

      Collavre::CronActionJob.stub(:perform_later, ->(**) { raise "queue unavailable" }) do
        CronSchedulerJob.perform_now
      end

      assert SolidQueue::RecurringTask.exists?(task.id)
    end

    test "keeps a run-once task with an unknown job class" do
      Collavre.const_set(:EphemeralCronJob, Class.new(ApplicationJob))
      task = SolidQueue::RecurringTask.create!(
        key: "cron_test_once_unknown",
        class_name: "Collavre::EphemeralCronJob",
        schedule: "*/5 * * * *",
        queue_name: "default",
        static: false,
        arguments: [ { creative_id: 1, once: true } ]
      )
      Collavre.send(:remove_const, :EphemeralCronJob)

      CronSchedulerJob.perform_now

      assert SolidQueue::RecurringTask.exists?(task.id)
    ensure
      Collavre.send(:remove_const, :EphemeralCronJob) if Collavre.const_defined?(:EphemeralCronJob, false)
    end

    test "handles a run-once task removed by another scheduler" do
      task = Struct.new(:arguments).new([ { creative_id: 1, once: true } ])
      def task.with_lock = raise(ActiveRecord::RecordNotFound)

      assert_equal false, CronSchedulerJob.new.send(:dispatch_task, task)
    end

    test "treats malformed arguments as recurring" do
      task = Struct.new(:arguments).new(nil)

      assert_equal false, CronSchedulerJob.new.send(:run_once?, task)
    end

    test "reschedules itself after perform" do
      assert_enqueued_with(job: Collavre::CronSchedulerJob) do
        CronSchedulerJob.perform_now
      end
    end

    test "does not reschedule if pending scheduler already exists" do
      # Simulate a pending CronSchedulerJob in SolidQueue
      SolidQueue::Job.create!(
        class_name: "Collavre::CronSchedulerJob",
        queue_name: "default",
        finished_at: nil
      )

      # Should not enqueue another CronSchedulerJob
      assert_no_enqueued_jobs(only: Collavre::CronSchedulerJob) do
        CronSchedulerJob.perform_now
      end
    end
  end
end
