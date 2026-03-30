# frozen_string_literal: true

require "test_helper"

module Collavre
  class DropTriggerJobTest < ActiveSupport::TestCase
    include ActiveJob::TestHelper

    setup do
      @owner = users(:one)
      @ai_bot = users(:ai_bot)
      Current.session = OpenStruct.new(user: @owner)

      perform_enqueued_jobs do
        @parent = Creative.create!(user: @owner, description: "Trigger Parent", data: { "trigger" => { "on_child_enter" => true } })
        @child = Creative.create!(user: @owner, description: "Dropped Child")
        CreativeShare.create!(creative: @parent, user: @ai_bot, permission: :write)
      end
    end

    teardown do
      Current.reset
    end

    test "creates trigger topic and comment on child creative" do
      SystemEvents::Dispatcher.stub(:dispatch, ->(*_args) { [ @ai_bot ] }) do
        assert_difference -> { @child.comments.count }, 1 do
          assert_difference -> { @child.topics.count }, 1 do
            DropTriggerJob.perform_now(@parent.id, @child.id)
          end
        end
      end

      topic = @child.topics.find_by(name: "Drop Trigger")
      assert topic, "Drop Trigger topic should be created on child"

      comment = @child.comments.last
      assert_includes comment.content, "@#{@ai_bot.name}:"
      assert_includes comment.content, @child.creative_snippet
    end

    test "dispatches exactly once via explicit call, not callback" do
      dispatch_calls = []
      dispatcher = ->(*args) { dispatch_calls << args; [ @ai_bot ] }

      SystemEvents::Dispatcher.stub(:dispatch, dispatcher) do
        DropTriggerJob.perform_now(@parent.id, @child.id)
      end

      # Dispatch should be called exactly once:
      # - after_create_commit callback is suppressed (skip_dispatch: true)
      # - Job dispatches explicitly in Step 3
      assert_equal 1, dispatch_calls.size, "Should dispatch exactly once (job only, not callback)"
    end

    test "reuses existing Drop Trigger topic" do
      SystemEvents::Dispatcher.stub(:dispatch, ->(*_args) { [ @ai_bot ] }) do
        DropTriggerJob.perform_now(@parent.id, @child.id)
      end

      assert_no_difference -> { @child.topics.count } do
        SystemEvents::Dispatcher.stub(:dispatch, ->(*_args) { [ @ai_bot ] }) do
          DropTriggerJob.perform_now(@parent.id, @child.id)
        end
      end
    end

    test "finds existing comment and retries dispatch on retry" do
      # First run: create comment, dispatch fails
      SystemEvents::Dispatcher.stub(:dispatch, ->(*_args) { raise "dispatch error" }) do
        assert_raises(RuntimeError) do
          DropTriggerJob.perform_now(@parent.id, @child.id)
        end
      end

      comment_count = @child.comments.count
      assert_operator comment_count, :>, 0, "Comment should be created even if dispatch fails"

      # Second run (retry): finds existing comment, retries dispatch successfully
      dispatch_calls = []
      dispatcher = ->(*args) { dispatch_calls << args; [ @ai_bot ] }

      SystemEvents::Dispatcher.stub(:dispatch, dispatcher) do
        assert_no_difference -> { @child.comments.count } do
          DropTriggerJob.perform_now(@parent.id, @child.id)
        end
      end

      assert_equal 1, dispatch_calls.size, "Should retry dispatch for existing comment"
    end

    test "skips dispatch when task already exists for comment" do
      dispatched = false
      SystemEvents::Dispatcher.stub(:dispatch, ->(*_args) { dispatched = true; [ @ai_bot ] }) do
        DropTriggerJob.perform_now(@parent.id, @child.id)
      end
      assert dispatched, "First run should dispatch"

      # Create a Task matching this comment
      comment = @child.comments.last
      topic = @child.topics.find_by(name: "Drop Trigger")
      Task.create!(
        name: "Response to comment_created",
        status: "running",
        trigger_event_name: "comment_created",
        trigger_event_payload: { "comment" => { "id" => comment.id } },
        agent_id: @ai_bot.id,
        creative_id: @child.id,
        topic_id: topic.id
      )

      dispatched = false
      SystemEvents::Dispatcher.stub(:dispatch, ->(*_args) { dispatched = true; [ @ai_bot ] }) do
        DropTriggerJob.perform_now(@parent.id, @child.id)
      end
      refute dispatched, "Should skip dispatch when Task already exists"
    end

    test "retries dispatch when existing task is cancelled" do
      SystemEvents::Dispatcher.stub(:dispatch, ->(*_args) { [ @ai_bot ] }) do
        DropTriggerJob.perform_now(@parent.id, @child.id)
      end

      comment = @child.comments.last
      topic = @child.topics.find_by(name: "Drop Trigger")
      Task.create!(
        name: "Response to comment_created",
        status: "cancelled",
        trigger_event_name: "comment_created",
        trigger_event_payload: { "comment" => { "id" => comment.id } },
        agent_id: @ai_bot.id,
        creative_id: @child.id,
        topic_id: topic.id
      )

      dispatched = false
      SystemEvents::Dispatcher.stub(:dispatch, ->(*_args) { dispatched = true; [ @ai_bot ] }) do
        DropTriggerJob.perform_now(@parent.id, @child.id)
      end
      assert dispatched, "Should retry dispatch when only a cancelled Task exists"
    end

    test "raises DispatchFailedError when dispatch returns no agents" do
      # retry_on reschedules the job; verify the error is raised on perform_now
      # by temporarily removing retry_on behavior
      SystemEvents::Dispatcher.stub(:dispatch, ->(*_args) { [] }) do
        error = assert_raises(Collavre::DropTriggerJob::DispatchFailedError) do
          # perform_now bypasses retry_on wait scheduling
          job = DropTriggerJob.new(@parent.id, @child.id)
          job.perform(@parent.id, @child.id)
        end
        assert_includes error.message, "no agents"
      end
    end

    test "comment survives dispatch failure for retry" do
      # Simulate first attempt: dispatch fails
      SystemEvents::Dispatcher.stub(:dispatch, ->(*_args) { [] }) do
        begin
          job = DropTriggerJob.new(@parent.id, @child.id)
          job.perform(@parent.id, @child.id)
        rescue Collavre::DropTriggerJob::DispatchFailedError
          # Expected
        end
      end

      # Comment should exist for next retry attempt
      topic = @child.topics.find_by(name: "Drop Trigger")
      assert topic, "Topic should exist"
      trigger_comment = @child.comments.where(topic_id: topic.id).where.not(user_id: nil).first
      assert trigger_comment, "Trigger comment should exist for retry"

      # Simulate retry: dispatch succeeds
      SystemEvents::Dispatcher.stub(:dispatch, ->(*_args) { [@ai_bot] }) do
        assert_no_difference -> { @child.comments.count } do
          DropTriggerJob.perform_now(@parent.id, @child.id)
        end
      end
    end

    test "skips when parent trigger is disabled" do
      @parent.update!(data: {})

      assert_no_difference -> { Comment.count } do
        DropTriggerJob.perform_now(@parent.id, @child.id)
      end
    end

    test "posts failure notice when no AI agent found" do
      CreativeShare.where(creative: @parent, user: @ai_bot).destroy_all

      assert_difference -> { @child.comments.count }, 1 do
        DropTriggerJob.perform_now(@parent.id, @child.id)
      end

      comment = @child.comments.last
      assert_nil comment.user_id, "Failure notice should be a system message (user_id: nil)"
      assert_includes comment.content, "⚠️"
      assert_includes comment.content, @parent.creative_snippet
    end

    test "failure notice does not dispatch to orchestration" do
      CreativeShare.where(creative: @parent, user: @ai_bot).destroy_all
      dispatched = false
      SystemEvents::Dispatcher.stub(:dispatch, ->(*_args) { dispatched = true; [] }) do
        DropTriggerJob.perform_now(@parent.id, @child.id)
      end

      refute dispatched, "System notice should not trigger orchestration dispatch"
    end

    test "skips when parent creative not found" do
      assert_no_difference -> { Comment.count } do
        DropTriggerJob.perform_now(0, @child.id)
      end
    end

    test "skips when child creative not found" do
      assert_no_difference -> { Comment.count } do
        DropTriggerJob.perform_now(@parent.id, 0)
      end
    end

    test "comment mentions the AI agent for routing" do
      SystemEvents::Dispatcher.stub(:dispatch, ->(*_args) { [ @ai_bot ] }) do
        DropTriggerJob.perform_now(@parent.id, @child.id)
      end

      comment = @child.comments.last
      assert comment.content.start_with?("@#{@ai_bot.name}:"),
        "Comment should start with @AgentName: mention"
    end

    test "uses creative_snippet for plain text names" do
      @child.update!(description: "<p>HTML <strong>description</strong> that is very long and should be truncated</p>")

      SystemEvents::Dispatcher.stub(:dispatch, ->(*_args) { [ @ai_bot ] }) do
        DropTriggerJob.perform_now(@parent.id, @child.id)
      end

      comment = @child.comments.last
      refute_includes comment.content, "<p>"
      refute_includes comment.content, "<strong>"
    end
  end
end
