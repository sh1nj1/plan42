# frozen_string_literal: true

require "test_helper"

class Collavre::TaskExecutionTimeTest < ActiveSupport::TestCase
  setup do
    @task = Collavre::Task.create!(name: "Timed task", agent: users(:one), status: "done")
    @started_at = Time.current.change(usec: 0)
  end

  test "measures execution events without queue time or later task updates" do
    @task.update_columns(created_at: @started_at - 5.minutes, updated_at: @started_at + 1.hour)
    event("start", 0)
    event("prompt_generated", 1)
    event("completion", 83.25)
    event("reply_created", 84)

    assert_equal 83.25, measured_seconds
  end

  test "uses the latest completed attempt" do
    event("start", 0)
    event("completion", 20)
    event("start", 100)
    event("completion", 130)

    assert_equal 30, measured_seconds
  end

  test "consecutive starts use the latest attempt boundary" do
    event("start", 0)
    event("start", 100)
    event("completion", 130)

    assert_equal 30, measured_seconds
  end

  test "does not reuse an earlier completion for a later attempt" do
    event("start", 0)
    event("completion", 20)
    event("start", 100)

    assert_nil measured_seconds
  end

  test "requires both start and completion" do
    assert_nil measured_seconds
    event("completion", 10)
    assert_nil measured_seconds
    @task.task_actions.delete_all
    event("start", 0)
    assert_nil measured_seconds
  end

  test "does not estimate delegated task completion from updated_at" do
    event("start", 0)
    event("delegated", 1)
    @task.update_columns(updated_at: @started_at + 60)

    assert_nil measured_seconds
  end

  test "does not show successful duration for unfinished or unsuccessful tasks" do
    event("start", 0)
    event("completion", 20)
    %w[pending queued running delegated pending_approval failed cancelled escalated].each do |status|
      @task.status = status
      assert_nil measured_seconds, status
    end
  end

  test "uses timestamps even if events were inserted out of order" do
    event("completion", 83)
    event("start", 0)

    assert_equal 83, measured_seconds
  end

  test "supports zero duration and deterministic ordering for equal timestamps" do
    event("start", 0)
    event("completion", 0)
    assert_equal 0, measured_seconds

    event("start", 0)
    assert_nil measured_seconds
  end

  private

  def measured_seconds
    @task.task_actions.reset
    queried = Collavre::TaskExecutionTime.seconds(@task)
    @task.task_actions.load
    preloaded = nil
    assert_no_queries do
      preloaded = Collavre::TaskExecutionTime.seconds(@task)
    end
    if queried.nil?
      assert_nil preloaded
    else
      assert_equal queried, preloaded
    end
    preloaded
  end

  def event(type, offset)
    @task.task_actions.create!(action_type: type, status: "done", created_at: @started_at + offset)
  end
end
