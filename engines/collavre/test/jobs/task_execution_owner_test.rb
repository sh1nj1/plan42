require "test_helper"

module Collavre
  class TaskExecutionOwnerTest < ActiveJob::TestCase
    setup do
      @previous_adapter = ActiveJob::Base.queue_adapter
      ActiveJob::Base.queue_adapter = :test
      @agent = users(:ai_bot)
    end

    teardown { ActiveJob::Base.queue_adapter = @previous_adapter }

    test "a new turn records its actual Active Job id before calling the provider" do
      job = AiAgentJob.new(@agent.id, "comment_created", {})
      observed = observe_execution { job.perform_now }
      assert_equal job.job_id, observed.fetch(:job_id)
      assert_equal "running", observed.fetch(:status)
    end

    test "resumption replaces the previous execution owner on the same task" do
      task = Task.create!(name: "Resumed", agent: @agent, status: "pending",
        trigger_event_payload: { "execution_job_id" => "old-worker-job" })
      job = AiAgentJob.new(task)
      observed = observe_execution { job.perform_now }
      assert_equal task.id, observed.fetch(:task_id)
      assert_equal job.job_id, observed.fetch(:job_id)
      assert_equal "running", observed.fetch(:status)
    end

    private

    def observe_execution
      observed = {}
      factory = lambda do |task|
        task.reload
        observed.merge!(task_id: task.id, job_id: task.trigger_event_payload["execution_job_id"], status: task.status)
        Object.new.tap { |service| service.define_singleton_method(:call) { true } }
      end
      AiAgentService.stub(:new, factory) { yield }
      observed
    end
  end
end
