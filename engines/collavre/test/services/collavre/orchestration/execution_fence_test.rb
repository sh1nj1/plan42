# frozen_string_literal: true

require "test_helper"

module Collavre
  module Orchestration
    class ExecutionFenceTest < ActiveSupport::TestCase
      test "stamp records a fresh generation and the owning job" do
        first = ExecutionFence.stamp({ "topic" => { "id" => 1 } }, job_id: "job-1")
        second = ExecutionFence.stamp(first)

        assert_equal({ "id" => 1 }, first["topic"])
        assert_equal "job-1", first[ExecutionFence::JOB_KEY]
        assert_not_nil first[ExecutionFence::GENERATION_KEY]
        assert_not_equal first[ExecutionFence::GENERATION_KEY], second[ExecutionFence::GENERATION_KEY]
        assert_not second.key?(ExecutionFence::JOB_KEY), "a start without a job must not inherit the previous owner"
      end

      test "stamp and clear accept a missing payload" do
        assert ExecutionFence.stamp(nil).key?(ExecutionFence::GENERATION_KEY)
        assert_equal({}, ExecutionFence.clear(nil))
      end

      test "clear drops only the execution keys" do
        payload = ExecutionFence.stamp({ "resume_context" => { "reason" => "quota" } }, job_id: "job-1")

        assert_equal({ "resume_context" => { "reason" => "quota" } }, ExecutionFence.clear(payload))
      end

      test "pending_handoff names the current generation and stamp or clear drop it" do
        payload = ExecutionFence.pending_handoff(ExecutionFence.stamp({}, job_id: "job-1"))

        assert_equal({ "generation" => payload[ExecutionFence::GENERATION_KEY], "state" => "pending" },
                     payload[ExecutionFence::HANDOFF_KEY])
        assert_not ExecutionFence.stamp(payload).key?(ExecutionFence::HANDOFF_KEY),
                   "a new attempt must not inherit the previous attempt's handoff"
        assert_equal({}, ExecutionFence.clear(payload))
        assert_equal({ "generation" => nil, "state" => "pending" }, ExecutionFence.pending_handoff(nil)[ExecutionFence::HANDOFF_KEY])
      end

      test "retire_attempt drops the generation and handoff but keeps the job" do
        payload = ExecutionFence.pending_handoff(ExecutionFence.stamp({ "topic" => { "id" => 1 } }, job_id: "job-1"))

        assert_equal({ "topic" => { "id" => 1 }, "execution_job_id" => "job-1" }, ExecutionFence.retire_attempt(payload))
        assert_equal({}, ExecutionFence.retire_attempt(nil))
      end

      test "retryable? needs the same job on a row without a payload" do
        assert_not ExecutionFence.retryable?(Task.new(status: "running", trigger_event_payload: nil), "job-1")
      end

      test "failed retries require the same job and exclude workflows and channel handoffs" do
        task = Task.new(status: "failed", trigger_event_payload: ExecutionFence.stamp({}, job_id: "job-1"))
        assert ExecutionFence.retryable?(task, "job-1")
        assert_not ExecutionFence.retryable?(task, "other-job")
        task.workflow_execution_id = 123
        assert_not ExecutionFence.retryable?(task, "job-1")
        task.workflow_execution_id = nil
        task.trigger_event_payload = ExecutionFence.pending_handoff(task.trigger_event_payload)
        assert_not ExecutionFence.retryable?(task, "job-1")
      end

      test "current? fences a named generation and lets an unnamed one through" do
        task = Task.new(trigger_event_payload: ExecutionFence.stamp({}))
        generation = ExecutionFence.generation(task)

        assert ExecutionFence.current?(task, generation)
        assert ExecutionFence.current?(task, nil)
        assert_not ExecutionFence.current?(task, "stale")
        assert_nil ExecutionFence.generation(Task.new(trigger_event_payload: nil))
      end

      test "superseded? tells a worker its attempt was resumed or restarted" do
        task = Task.new(trigger_event_payload: ExecutionFence.stamp({}))
        attempt = ExecutionFence.generation(task)

        assert_not ExecutionFence.superseded?(task, attempt)
        assert_not ExecutionFence.superseded?(task, nil), "a worker from before the fence is not fenced"

        task.trigger_event_payload = ExecutionFence.clear(task.trigger_event_payload)
        assert ExecutionFence.superseded?(task, attempt), "resumed, not started again yet"

        task.trigger_event_payload = ExecutionFence.stamp(task.trigger_event_payload)
        assert ExecutionFence.superseded?(task, attempt), "started again as a new attempt"
      end

      test "retired? is false until offline recovery installs its tombstones" do
        assert_not ExecutionFence.retired?("job-1")
      end
    end
  end
end
