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
