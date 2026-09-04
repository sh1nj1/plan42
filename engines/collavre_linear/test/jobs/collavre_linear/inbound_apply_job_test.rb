# frozen_string_literal: true

require "test_helper"

module CollavreLinear
  class InboundApplyJobTest < ActiveSupport::TestCase
    include ActiveJob::TestHelper

    def setup
      @original_adapter = ActiveJob::Base.queue_adapter
      ActiveJob::Base.queue_adapter = :test
    end

    def teardown
      ActiveJob::Base.queue_adapter = @original_adapter
    end

    test "perform_later enqueues the job with the payload" do
      payload = { "action" => "update" }
      assert_enqueued_with(job: CollavreLinear::InboundApplyJob, args: [ payload ]) do
        CollavreLinear::InboundApplyJob.perform_later(payload)
      end
    end

    test "runs on the dedicated sequential linear_inbound queue" do
      # Inbound applies must process strictly in receipt order — a comment can
      # arrive before its issue's create, and concurrent workers on a shared
      # queue would apply them out of order (dropping the comment). config/
      # queue.yml gives linear_inbound a single-thread, single-process worker so
      # this queue is a sequential FIFO consumer.
      assert_equal "linear_inbound", CollavreLinear::InboundApplyJob.new.queue_name
    end

    test "perform delegates to InboundApplier#apply!" do
      payload = { "action" => "update", "data" => { "id" => "iss-1" } }
      captured = nil
      applied  = false

      applier_stub = Class.new do
        define_method(:initialize) { |p| captured = p }
        define_method(:apply!) { applied = true }
      end

      # InboundApplier is a Task 10 dependency; stub it here so this task's job
      # can be validated in isolation.
      CollavreLinear.send(:const_set, :InboundApplier, applier_stub) unless
        CollavreLinear.const_defined?(:InboundApplier, false)

      CollavreLinear::InboundApplier.stub(:new, lambda { |p|
        captured = p
        obj = Object.new
        obj.define_singleton_method(:apply!) { applied = true }
        obj
      }) do
        CollavreLinear::InboundApplyJob.perform_now(payload)
      end

      assert_equal payload, captured, "job must hand the payload to InboundApplier.new"
      assert applied, "job must call apply! on the InboundApplier"
    end

    test "records actorless inbound writes as hidden sync history" do
      creative = creatives(:tshirt)
      applier = Object.new
      applier.define_singleton_method(:apply!) { creative.update!(description: "Linear update") }

      CollavreLinear::InboundApplier.stub(:new, ->(*) { applier }) do
        CollavreLinear::InboundApplyJob.perform_now({ "action" => "update" })
      end

      change_set = Collavre::CreativeChangeSet.sole
      assert_equal "sync", change_set.origin
      assert_equal "sync", change_set.actor_kind
      assert_nil change_set.anchor_creative_id
      assert_empty Collavre::CreativeChangeSet.visible_by_default
    end

    test "a transient ActiveRecord::Deadlocked re-enqueues (retry) instead of dropping the event" do
      # WebhooksController acks Linear (200) before this job runs, so a dropped
      # apply is never re-delivered. A transient deadlock must retry, not park.
      deadlocking = lambda { |_p|
        obj = Object.new
        obj.define_singleton_method(:apply!) { raise ActiveRecord::Deadlocked, "deadlock" }
        obj
      }

      CollavreLinear::InboundApplier.stub(:new, deadlocking) do
        assert_enqueued_with(job: CollavreLinear::InboundApplyJob) do
          # retry_on rescues the deadlock and re-enqueues the job for a later run.
          CollavreLinear::InboundApplyJob.perform_now(
            { "action" => "update", "data" => { "id" => "iss-1" } }
          )
        end
      end
    end

    test "a non-transient error surfaces and parks — it is NOT auto-retried" do
      # Real bugs must fail loudly (operator-visible failed execution), not loop.
      boom = lambda { |_p|
        obj = Object.new
        obj.define_singleton_method(:apply!) { raise "boom" }
        obj
      }

      CollavreLinear::InboundApplier.stub(:new, boom) do
        assert_no_enqueued_jobs do
          assert_raises(RuntimeError) do
            CollavreLinear::InboundApplyJob.perform_now(
              { "action" => "update", "data" => { "id" => "iss-1" } }
            )
          end
        end
      end
    end

    test "perform is silent when InboundApplier is not yet defined" do
      # Simulate the Task-10-not-built state: no InboundApplier constant.
      had_const = CollavreLinear.const_defined?(:InboundApplier, false)
      saved = CollavreLinear.send(:remove_const, :InboundApplier) if had_const

      begin
        assert_nothing_raised do
          CollavreLinear::InboundApplyJob.perform_now({ "action" => "update" })
        end
      ensure
        CollavreLinear.send(:const_set, :InboundApplier, saved) if had_const
      end
    end
  end
end
