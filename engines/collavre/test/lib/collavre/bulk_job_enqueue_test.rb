# frozen_string_literal: true

require "test_helper"

module Collavre
  class BulkJobEnqueueTest < ActiveSupport::TestCase
    include ActiveJob::TestHelper

    EVENTS = []

    class RecordingJob < ActiveJob::Base
      before_enqueue { |job| EVENTS << [ :before, job.arguments.first ] }
      after_enqueue { |job| EVENTS << [ :after, job.arguments.first, job.provider_job_id.present?, job.successfully_enqueued? ] }

      def perform(*); end
    end

    class OtherQueueJob < ActiveJob::Base
      queue_as :authz

      def perform(*); end
    end

    class AckJob < ActiveJob::Base
      def perform(*); end
    end

    class HaltingJob < ActiveJob::Base
      before_enqueue { throw :abort }

      def perform(*); end
    end

    class EnqueuingCallbackJob < ActiveJob::Base
      after_enqueue { RecordingJob.perform_later("from callback") }

      def perform(*); end
    end

    class AfterCommitJob < ActiveJob::Base
      self.enqueue_after_transaction_commit = true

      def perform(*); end
    end

    DEFERRABLE = %w[
      Collavre::BulkJobEnqueueTest::RecordingJob
      Collavre::BulkJobEnqueueTest::OtherQueueJob
      Collavre::BulkJobEnqueueTest::HaltingJob
      Collavre::BulkJobEnqueueTest::EnqueuingCallbackJob
      Collavre::BulkJobEnqueueTest::AfterCommitJob
    ].freeze

    def queue_adapter_for_test
      ActiveJob::QueueAdapters::SolidQueueAdapter.new
    end

    setup do
      EVENTS.clear
      @baseline_job_id = SolidQueue::Job.maximum(:id).to_i
    end

    test "defers listed jobs until the block ends and writes them in one bulk insert" do
      bulk_calls = count_bulk_calls do
        BulkJobEnqueue.collect(deferrable: DEFERRABLE) do
          job = RecordingJob.perform_later("a", { "k" => 1 })
          OtherQueueJob.set(priority: 7).perform_later("b")
          RecordingJob.set(wait: 1.hour).perform_later("c")

          assert job.successfully_enqueued?
          assert_nil job.provider_job_id
          assert_empty new_jobs
        end
      end

      assert_equal 1, bulk_calls
      rows = new_jobs
      assert_equal [ RecordingJob.name, OtherQueueJob.name, RecordingJob.name ], rows.map(&:class_name)
      assert_equal [ "default", "authz", "default" ], rows.map(&:queue_name)
      assert_equal [ 0, 7, 0 ], rows.map(&:priority)
      assert_equal [ [ "a", { "k" => 1 } ], [ "b" ], [ "c" ] ], rows.map { |row| ActiveJob::Arguments.deserialize(row.arguments["arguments"]) }
      assert rows[0].ready_execution
      assert rows[2].scheduled_execution
      assert_in_delta 1.hour.from_now.to_f, rows[2].scheduled_at.to_f, 5
    end

    test "runs each job's enqueue callbacks around the actual write" do
      enqueue_events = []
      subscriber = ActiveSupport::Notifications.subscribe("enqueue.active_job") do |*, payload|
        enqueue_events << [ payload[:job].arguments.first, payload[:job].successfully_enqueued? ]
      end

      BulkJobEnqueue.collect(deferrable: DEFERRABLE) do
        RecordingJob.perform_later("first")
        RecordingJob.perform_later("second")
        assert_empty EVENTS
      end

      assert_equal [
        [ :before, "first" ], [ :before, "second" ],
        [ :after, "second", true, true ], [ :after, "first", true, true ]
      ], EVENTS
      assert_equal [ [ "second", true ], [ "first", true ] ], enqueue_events
    ensure
      ActiveSupport::Notifications.unsubscribe(subscriber)
    end

    test "a job outside the deferrable list flushes pending jobs with itself and reports the real outcome" do
      bulk_calls = count_bulk_calls do
        BulkJobEnqueue.collect(deferrable: DEFERRABLE) do
          RecordingJob.perform_later("pending")
          ack = AckJob.perform_later("ack")

          assert ack.successfully_enqueued?
          assert ack.provider_job_id.present?
          assert_equal [ RecordingJob.name, AckJob.name ], new_jobs.map(&:class_name)
          RecordingJob.perform_later("after")
        end
      end

      assert_equal 2, bulk_calls
      assert_equal [ RecordingJob.name, AckJob.name, RecordingJob.name ], new_jobs.map(&:class_name)
    end

    test "a halted enqueue skips only that job" do
      BulkJobEnqueue.collect(deferrable: DEFERRABLE) do
        RecordingJob.perform_later("kept")
        HaltingJob.perform_later("dropped")
        RecordingJob.perform_later("also kept")
      end

      assert_equal [ RecordingJob.name, RecordingJob.name ], new_jobs.map(&:class_name)
    end

    test "a halted job outside the deferrable list returns false" do
      result = BulkJobEnqueue.collect(deferrable: []) { HaltingJob.perform_later("dropped") }

      assert_equal false, result
      assert_empty new_jobs
    end

    test "jobs enqueued from an enqueue callback during the final flush take the regular path" do
      BulkJobEnqueue.collect(deferrable: DEFERRABLE) { EnqueuingCallbackJob.perform_later }

      assert_equal [ EnqueuingCallbackJob.name, RecordingJob.name ], new_jobs.map(&:class_name)
    end

    test "falls back to one-by-one enqueue when the bulk insert fails" do
      SolidQueue::Job.stub(:enqueue_all, ->(*) { raise ActiveRecord::StatementInvalid, "queue down" }) do
        BulkJobEnqueue.collect(deferrable: DEFERRABLE) do
          RecordingJob.perform_later("one")
          RecordingJob.set(wait: 10.minutes).perform_later("two")
        end
      end

      rows = new_jobs
      assert_equal [ [ "one" ], [ "two" ] ], rows.map { |row| row.arguments["arguments"] }
      assert rows[0].ready_execution
      assert rows[1].scheduled_execution
      assert_equal [ [ :before, "one" ], [ :before, "two" ], [ :after, "two", true, true ], [ :after, "one", true, true ] ], EVENTS
    end

    test "fallback keeps the adapter's per-job enqueue error handling" do
      failing = ->(*) { raise ActiveJob::EnqueueError, "rejected" }
      ack = nil
      SolidQueue::Job.stub(:enqueue_all, failing) do
        SolidQueue::Job.stub(:enqueue, failing) do
          ack = BulkJobEnqueue.collect(deferrable: []) { AckJob.perform_later("x") }
        end
      end

      assert_equal false, ack
      assert_empty new_jobs
    end

    test "jobs whose adapter cannot bulk insert keep the regular path, after pending jobs" do
      inline = ActiveJob::QueueAdapters::TestAdapter.new
      AckJob.stub(:queue_adapter, inline) do
        BulkJobEnqueue.collect(deferrable: DEFERRABLE) do
          RecordingJob.perform_later("pending")
          AckJob.perform_later("test adapter")

          assert_equal [ RecordingJob.name ], new_jobs.map(&:class_name)
          assert_equal 1, inline.enqueued_jobs.size
        end
      end
    end

    test "jobs deferred until transaction commit keep the regular path" do
      BulkJobEnqueue.collect(deferrable: DEFERRABLE) do
        AfterCommitJob.perform_later("deferred by rails")
        assert_equal [ AfterCommitJob.name ], new_jobs.map(&:class_name)
      end
    end

    test "flushes already enqueued jobs and re-raises when the block fails" do
      error = assert_raises(RuntimeError) do
        BulkJobEnqueue.collect(deferrable: DEFERRABLE) do
          RecordingJob.perform_later("before failure")
          raise "callback failed"
        end
      end

      assert_equal "callback failed", error.message
      assert_equal [ RecordingJob.name ], new_jobs.map(&:class_name)
      assert_nil BulkJobEnqueue.current
    end

    test "a flush error during a failing block is logged instead of masking the original error" do
      logged = []
      Rails.logger.stub(:error, ->(message = nil, &block) { logged << (message || block&.call).to_s }) do
        SolidQueue::Job.stub(:enqueue_all, ->(*) { raise ArgumentError, "flush broke" }) do
          error = assert_raises(RuntimeError) do
            BulkJobEnqueue.collect(deferrable: DEFERRABLE) do
              RecordingJob.perform_later("lost")
              raise "callback failed"
            end
          end
          assert_equal "callback failed", error.message
        end
      end

      assert(logged.any? { |message| message.include?("ArgumentError: flush broke") })
    end

    test "a nested collect joins the outer scope" do
      bulk_calls = count_bulk_calls do
        BulkJobEnqueue.collect(deferrable: DEFERRABLE) do
          RecordingJob.perform_later("outer")
          assert_equal :inner, BulkJobEnqueue.collect(deferrable: DEFERRABLE) { RecordingJob.perform_later("inner") && :inner }
          assert_empty new_jobs
        end
      end

      assert_equal 1, bulk_calls
      assert_equal 2, new_jobs.size
    end

    test "returns the block value and leaves enqueues outside a scope untouched" do
      assert_equal :done, BulkJobEnqueue.collect(deferrable: DEFERRABLE) { :done }

      job = RecordingJob.perform_later("plain")
      assert job.provider_job_id.present?
      assert_nil BulkJobEnqueue.current
    end

    private

    def new_jobs
      SolidQueue::Job.where("id > ?", @baseline_job_id).order(:id).to_a
    end

    def count_bulk_calls
      calls = 0
      original = SolidQueue::Job.method(:enqueue_all)
      SolidQueue::Job.stub(:enqueue_all, ->(jobs) { calls += 1; original.call(jobs) }) { yield }
      calls
    end
  end
end
