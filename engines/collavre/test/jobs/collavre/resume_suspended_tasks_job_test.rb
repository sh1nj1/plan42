# frozen_string_literal: true

require "test_helper"

module Collavre
  class ResumeSuspendedTasksJobTest < ActiveSupport::TestCase
    test "resumes a single task by id" do
      task = Task.create!(name: "Turn", status: "done", agent: users(:ai_bot))
      calls = []

      Orchestration::TaskResumer.stub(:resume!, ->(t) { calls << t.id }) do
        ResumeSuspendedTasksJob.perform_now(task_id: task.id)
        ResumeSuspendedTasksJob.perform_now(task_id: -1)
      end

      assert_equal [ task.id ], calls
    end

    test "resumes an agent's due tasks" do
      calls = []
      Orchestration::TaskResumer.stub(:resume_for_agent!, ->(id) { calls << id }) do
        ResumeSuspendedTasksJob.perform_now(agent_id: 42)
      end
      assert_equal [ 42 ], calls
    end

    test "sweeps without arguments" do
      swept = false
      Orchestration::TaskResumer.stub(:sweep!, -> { swept = true }) do
        ResumeSuspendedTasksJob.perform_now
      end
      assert swept
    end

    test "is scheduled in every queue environment" do
      schedules = YAML.load_file(Rails.root.join("config/recurring.yml"), aliases: true)

      %w[production desktop development].each do |environment|
        task = schedules.fetch(environment).fetch("resume_suspended_tasks")
        assert_equal "Collavre::ResumeSuspendedTasksJob", task.fetch("class")
        assert_equal "every 5 minutes", task.fetch("schedule")
      end
    end
  end
end
