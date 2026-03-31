# frozen_string_literal: true

require "test_helper"

module Collavre
  class TriggerLoopCheckJobTest < ActiveSupport::TestCase
    include ActiveJob::TestHelper

    setup do
      @human = users(:one)
      @ai_bot = users(:ai_bot)

      # Parent creative with drop trigger config (no loop state here)
      @parent = Creative.create!(
        description: "Parent with trigger",
        user: @human,
        data: {
          "trigger" => {
            "on_child_enter" => true
          }
        }
      )
      CreativeShare.create!(creative: @parent, user: @ai_bot, permission: :write)

      # Create child without parent first, then move it (to avoid triggering DropTriggerJob)
      @child = Creative.create!(
        description: "Child task",
        user: @human
      )
      Creative.where(id: @child.id).update_all(parent_id: @parent.id)
      @child.reload

      @topic = @child.topics.create!(name: "Drop Trigger", user: @human)

      # Loop state lives on the child creative (each child has its own loop)
      @child.update!(data: {
        "trigger" => {
          "loop" => {
            "state" => "running",
            "current_iteration" => 0,
            "max_iterations" => 3,
            "completion_conditions" => [ "pr created" ],
            "stuck_conditions" => [ "need help" ],
            "on_retry" => "continue",
            "cooldown_seconds" => 0,
            "trigger_topic_id" => @topic.id
          }
        }
      })

      # Create task with status "running" first, then update to "done" quietly
      # to avoid triggering the after_update_commit callback during setup
      @task = Task.create!(
        name: "Response to comment_created",
        status: "running",
        trigger_event_name: "comment_created",
        trigger_event_payload: { "comment" => { "id" => 999 } },
        agent_id: @ai_bot.id,
        creative_id: @child.id,
        topic_id: @topic.id
      )
      Task.where(id: @task.id).update_all(status: "done")
    end

    test "completes loop when agent reports STATUS: DONE" do
      @child.comments.create!(
        content: "All done! [STATUS: DONE]",
        topic_id: @topic.id,
        user: @ai_bot,
        created_at: @task.created_at + 1.second
      )

      TriggerLoopCheckJob.perform_now(@task.id)

      @child.reload
      assert_equal "completed", @child.data.dig("trigger", "loop", "state")
    end

    test "completes loop when agent reports STATUS: BLOCKED" do
      @child.comments.create!(
        content: "Cannot proceed [STATUS: BLOCKED need credentials]",
        topic_id: @topic.id,
        user: @ai_bot,
        created_at: @task.created_at + 1.second
      )

      SystemEvents::Dispatcher.stub(:dispatch, ->(*_args) { [] }) do
        assert_difference -> { @child.comments.count }, 1 do
          TriggerLoopCheckJob.perform_now(@task.id)
        end
      end

      @child.reload
      assert_equal "stuck", @child.data.dig("trigger", "loop", "state")
      assert_includes @child.comments.last.content, "⚠️"
    end

    test "continues loop when agent reports STATUS: CONTINUE" do
      @child.comments.create!(
        content: "Working on it [STATUS: CONTINUE]",
        topic_id: @topic.id,
        user: @ai_bot,
        created_at: @task.created_at + 1.second
      )

      SystemEvents::Dispatcher.stub(:dispatch, ->(*_args) { [ @ai_bot ] }) do
        assert_difference -> { @child.comments.count }, 1 do
          TriggerLoopCheckJob.perform_now(@task.id)
        end
      end

      @child.reload
      assert_equal "running", @child.data.dig("trigger", "loop", "state")
      assert_equal 1, @child.data.dig("trigger", "loop", "current_iteration")

      continue_comment = @child.comments.last
      assert_includes continue_comment.content, "@#{@ai_bot.name}:"
      assert_includes continue_comment.content, "🔄"
    end

    test "stops at max iterations" do
      @child.data["trigger"]["loop"]["current_iteration"] = 2
      @child.save!

      @child.comments.create!(
        content: "Still working [STATUS: CONTINUE]",
        topic_id: @topic.id,
        user: @ai_bot,
        created_at: @task.created_at + 1.second
      )

      SystemEvents::Dispatcher.stub(:dispatch, ->(*_args) { [] }) do
        TriggerLoopCheckJob.perform_now(@task.id)
      end

      @child.reload
      assert_equal "max_reached", @child.data.dig("trigger", "loop", "state")
    end

    test "does NOT complete on keyword match alone — requires explicit STATUS DONE tag" do
      @child.update!(data: {
        "trigger" => {
          "loop" => @child.data.dig("trigger", "loop").merge(
            "completion_conditions" => [ "pr created" ]
          )
        }
      })

      @child.comments.create!(
        content: "I have pr created successfully",
        topic_id: @topic.id,
        user: @ai_bot,
        created_at: @task.created_at + 1.second
      )

      # Without explicit [STATUS: DONE], keyword match defaults to continue
      SystemEvents::Dispatcher.stub(:dispatch, ->(*_args) { [ @ai_bot ] }) do
        TriggerLoopCheckJob.perform_now(@task.id)
      end

      @child.reload
      assert_equal "running", @child.data.dig("trigger", "loop", "state")
      assert_equal 1, @child.data.dig("trigger", "loop", "current_iteration")
    end

    test "retries without consuming iteration on infrastructure error (timeout)" do
      @child.comments.create!(
        content: "OpenClaw Error: OpenClaw request timed out after 3 attempts",
        topic_id: @topic.id,
        user: @ai_bot,
        created_at: @task.created_at + 1.second
      )

      SystemEvents::Dispatcher.stub(:dispatch, ->(*_args) { [ @ai_bot ] }) do
        TriggerLoopCheckJob.perform_now(@task.id)
      end

      @child.reload
      # Iteration stays at 0 — not consumed
      assert_equal 0, @child.data.dig("trigger", "loop", "current_iteration")
      assert_equal "running", @child.data.dig("trigger", "loop", "state")
      assert_equal 1, @child.data.dig("trigger", "loop", "infra_retry_count")
      # Retry comment uses distinct message (not "continue where you left off")
      last_comment = @child.comments.last
      assert_includes last_comment.content, "🔄"
    end

    test "retries without consuming iteration on connection error" do
      @child.comments.create!(
        content: "OpenClaw Error: connection refused",
        topic_id: @topic.id,
        user: @ai_bot,
        created_at: @task.created_at + 1.second
      )

      SystemEvents::Dispatcher.stub(:dispatch, ->(*_args) { [ @ai_bot ] }) do
        TriggerLoopCheckJob.perform_now(@task.id)
      end

      @child.reload
      assert_equal 0, @child.data.dig("trigger", "loop", "current_iteration")
      assert_equal "running", @child.data.dig("trigger", "loop", "state")
      assert_equal 1, @child.data.dig("trigger", "loop", "infra_retry_count")
    end

    test "transitions to stuck after MAX_INFRA_RETRIES consecutive infra errors" do
      # Set infra_retry_count to 2 (one below MAX_INFRA_RETRIES=3)
      @child.data["trigger"]["loop"]["infra_retry_count"] = 2
      @child.save!

      @child.comments.create!(
        content: "OpenClaw Error: server timed out",
        topic_id: @topic.id,
        user: @ai_bot,
        created_at: @task.created_at + 1.second
      )

      SystemEvents::Dispatcher.stub(:dispatch, ->(*_args) { [] }) do
        TriggerLoopCheckJob.perform_now(@task.id)
      end

      @child.reload
      assert_equal "stuck", @child.data.dig("trigger", "loop", "state")
      assert_equal 3, @child.data.dig("trigger", "loop", "infra_retry_count")
      assert_includes @child.comments.last.content, "⚠️"
      assert_includes @child.comments.last.content, "3"
    end

    test "resets infra_retry_count on successful agent response" do
      @child.data["trigger"]["loop"]["infra_retry_count"] = 2
      @child.save!

      @child.comments.create!(
        content: "Making progress [STATUS: CONTINUE]",
        topic_id: @topic.id,
        user: @ai_bot,
        created_at: @task.created_at + 1.second
      )

      SystemEvents::Dispatcher.stub(:dispatch, ->(*_args) { [ @ai_bot ] }) do
        TriggerLoopCheckJob.perform_now(@task.id)
      end

      @child.reload
      assert_equal 0, @child.data.dig("trigger", "loop", "infra_retry_count")
      assert_equal "running", @child.data.dig("trigger", "loop", "state")
    end

    test "does not false-positive on creative IDs containing 502/503/504" do
      @child.comments.create!(
        content: "Updated Creative #10504 successfully [STATUS: CONTINUE]",
        topic_id: @topic.id,
        user: @ai_bot,
        created_at: @task.created_at + 1.second
      )

      SystemEvents::Dispatcher.stub(:dispatch, ->(*_args) { [ @ai_bot ] }) do
        TriggerLoopCheckJob.perform_now(@task.id)
      end

      @child.reload
      # Should NOT be treated as infra error — should continue normally
      assert_equal "running", @child.data.dig("trigger", "loop", "state")
      assert_equal 1, @child.data.dig("trigger", "loop", "current_iteration")
    end

    test "falls back to stuck_conditions keywords" do
      @child.comments.create!(
        content: "I need help with this",
        topic_id: @topic.id,
        user: @ai_bot,
        created_at: @task.created_at + 1.second
      )

      SystemEvents::Dispatcher.stub(:dispatch, ->(*_args) { [] }) do
        TriggerLoopCheckJob.perform_now(@task.id)
      end

      @child.reload
      assert_equal "stuck", @child.data.dig("trigger", "loop", "state")
    end

    test "defaults to continue when no status tag or keywords match" do
      @child.comments.create!(
        content: "I made some changes to the codebase",
        topic_id: @topic.id,
        user: @ai_bot,
        created_at: @task.created_at + 1.second
      )

      SystemEvents::Dispatcher.stub(:dispatch, ->(*_args) { [ @ai_bot ] }) do
        TriggerLoopCheckJob.perform_now(@task.id)
      end

      @child.reload
      assert_equal "running", @child.data.dig("trigger", "loop", "state")
      assert_equal 1, @child.data.dig("trigger", "loop", "current_iteration")
    end

    test "skips when loop state is not running" do
      @child.data["trigger"]["loop"]["state"] = "completed"
      @child.save!

      @child.comments.create!(
        content: "Some response [STATUS: CONTINUE]",
        topic_id: @topic.id,
        user: @ai_bot,
        created_at: @task.created_at + 1.second
      )

      assert_no_difference -> { @child.comments.count } do
        TriggerLoopCheckJob.perform_now(@task.id)
      end
    end

    test "skips when no agent comment found" do
      assert_no_difference -> { @child.comments.count } do
        TriggerLoopCheckJob.perform_now(@task.id)
      end
    end

    test "skips when task is from a different topic than trigger_topic_id" do
      other_topic = @child.topics.create!(name: "General Discussion", user: @human)

      # Task is in a different topic
      other_task = Task.create!(
        name: "Response to comment_created",
        status: "running",
        trigger_event_name: "comment_created",
        trigger_event_payload: { "comment" => { "id" => 888 } },
        agent_id: @ai_bot.id,
        creative_id: @child.id,
        topic_id: other_topic.id
      )
      Task.where(id: other_task.id).update_all(status: "done")

      @child.comments.create!(
        content: "Some work done [STATUS: DONE]",
        topic_id: other_topic.id,
        user: @ai_bot,
        created_at: other_task.created_at + 1.second
      )

      # The task callback should NOT enqueue TriggerLoopCheckJob for wrong topic
      # Even if we call the job directly, loop state should not change
      # because find_last_agent_comment scopes to task.topic_id
      assert_no_difference -> { @child.comments.where(topic_id: @topic.id).count } do
        TriggerLoopCheckJob.perform_now(other_task.id)
      end

      @child.reload
      assert_equal "running", @child.data.dig("trigger", "loop", "state")
    end

    test "skips when parent has no drop trigger" do
      @parent.data.delete("trigger")
      @parent.save!

      @child.update!(data: {})  # Also clear child trigger data

      assert_no_difference -> { @child.comments.count } do
        TriggerLoopCheckJob.perform_now(@task.id)
      end
    end
  end
end
