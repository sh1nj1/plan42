# frozen_string_literal: true

require "test_helper"

module Collavre
  class TriggerLoopCheckJobTest < ActiveSupport::TestCase
    include ActiveJob::TestHelper

    setup do
      @human = users(:one)
      @ai_bot = users(:ai_bot)

      # Parent creative with drop trigger + loop config
      @parent = Creative.create!(
        description: "Parent with trigger",
        user: @human,
        data: {
          "trigger" => {
            "on_child_enter" => true,
            "loop" => {
              "state" => "running",
              "current_iteration" => 0,
              "max_iterations" => 3,
              "completion_conditions" => [ "pr created" ],
              "stuck_conditions" => [ "need help" ],
              "on_retry" => "continue",
              "topic_id" => nil,
              "cooldown_seconds" => 0
            }
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
      @parent.data["trigger"]["loop"]["topic_id"] = @topic.id
      @parent.save!

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

      @parent.reload
      assert_equal "completed", @parent.data.dig("trigger", "loop", "state")
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

      @parent.reload
      assert_equal "stuck", @parent.data.dig("trigger", "loop", "state")
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

      @parent.reload
      assert_equal "running", @parent.data.dig("trigger", "loop", "state")
      assert_equal 1, @parent.data.dig("trigger", "loop", "current_iteration")

      continue_comment = @child.comments.last
      assert_includes continue_comment.content, "@#{@ai_bot.name}:"
      assert_includes continue_comment.content, "🔄"
    end

    test "stops at max iterations" do
      @parent.data["trigger"]["loop"]["current_iteration"] = 2
      @parent.save!

      @child.comments.create!(
        content: "Still working [STATUS: CONTINUE]",
        topic_id: @topic.id,
        user: @ai_bot,
        created_at: @task.created_at + 1.second
      )

      SystemEvents::Dispatcher.stub(:dispatch, ->(*_args) { [] }) do
        TriggerLoopCheckJob.perform_now(@task.id)
      end

      @parent.reload
      assert_equal "max_reached", @parent.data.dig("trigger", "loop", "state")
    end

    test "falls back to completion_conditions keywords" do
      @child.comments.create!(
        content: "I have pr created successfully",
        topic_id: @topic.id,
        user: @ai_bot,
        created_at: @task.created_at + 1.second
      )

      SystemEvents::Dispatcher.stub(:dispatch, ->(*_args) { [] }) do
        TriggerLoopCheckJob.perform_now(@task.id)
      end

      @parent.reload
      assert_equal "completed", @parent.data.dig("trigger", "loop", "state")
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

      @parent.reload
      assert_equal "stuck", @parent.data.dig("trigger", "loop", "state")
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

      @parent.reload
      assert_equal "running", @parent.data.dig("trigger", "loop", "state")
      assert_equal 1, @parent.data.dig("trigger", "loop", "current_iteration")
    end

    test "skips when loop state is not running" do
      @parent.data["trigger"]["loop"]["state"] = "completed"
      @parent.save!

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

    test "skips when parent has no drop trigger" do
      @parent.data.delete("trigger")
      @parent.save!

      assert_no_difference -> { @child.comments.count } do
        TriggerLoopCheckJob.perform_now(@task.id)
      end
    end
  end
end
