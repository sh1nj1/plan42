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

      test "current? fences a named generation and lets an unnamed one through" do
        task = Task.new(trigger_event_payload: ExecutionFence.stamp({}))
        generation = ExecutionFence.generation(task)

        assert ExecutionFence.current?(task, generation)
        assert ExecutionFence.current?(task, nil)
        assert_not ExecutionFence.current?(task, "stale")
        assert_nil ExecutionFence.generation(Task.new(trigger_event_payload: nil))
      end
    end
  end
end
