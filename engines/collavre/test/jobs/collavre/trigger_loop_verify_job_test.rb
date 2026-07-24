# frozen_string_literal: true

require "test_helper"

module Collavre
  class TriggerLoopVerifyJobTest < ActiveSupport::TestCase
    include ActiveJob::TestHelper

    setup do
      @human = users(:one)
      @ai_bot = users(:ai_bot)

      @parent = Creative.create!(
        description: "Parent with trigger",
        user: @human,
        data: {
          "trigger" => { "on_child_enter" => true }
        }
      )
      CreativeShare.create!(creative: @parent, user: @ai_bot, permission: :write)

      # Create child without parent, then move it to avoid DropTriggerJob
      @child = Creative.create!(
        description: "Child task",
        user: @human
      )
      Creative.where(id: @child.id).update_all(parent_id: @parent.id)
      @child.reload

      @topic = @child.topics.create!(name: "Drop Trigger", user: @human)

      @child.update!(data: {
        "trigger" => {
          "loop" => {
            "state" => "pending_verification",
            "current_iteration" => 1,
            "max_iterations" => 10,
            "trigger_topic_id" => @topic.id,
            "last_task_id" => nil,
            "cooldown_seconds" => 0,
            "infra_retry_count" => 0
          }
        }
      })

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

      @agent_comment = @child.comments.create!(
        content: "I have completed all tasks. PR created and creative moved. [STATUS: DONE]",
        topic_id: @topic.id,
        user: @ai_bot,
        skip_dispatch: true,
        created_at: @task.created_at + 1.second
      )
    end

    test "completes loop when verification returns VERIFIED" do
      mock_client = mock_ai_client("VERIFIED")

      AiClient.stub(:new, mock_client) do
        TriggerLoopVerifyJob.perform_now(@task.id)
      end

      @child.reload
      assert_equal "completed", @child.data.dig("trigger", "loop", "state")
    end

    test "continues loop when verification returns INCOMPLETE" do
      mock_client = mock_ai_client("INCOMPLETE: creative not moved to review")

      AiClient.stub(:new, mock_client) do
        # Stub SystemEvents::Dispatcher to prevent dispatch errors
        SystemEvents::Dispatcher.stub(:dispatch, []) do
          TriggerLoopVerifyJob.perform_now(@task.id)
        end
      end

      @child.reload
      assert_equal "running", @child.data.dig("trigger", "loop", "state")
      assert_equal 2, @child.data.dig("trigger", "loop", "current_iteration")
    end

    test "accepts DONE when LLM call fails (graceful degradation)" do
      error_client = ->(**opts) {
        obj = Object.new
        obj.define_singleton_method(:chat) { |messages, &block| raise StandardError, "LLM API error" }
        obj
      }

      AiClient.stub(:new, error_client) do
        TriggerLoopVerifyJob.perform_now(@task.id)
      end

      @child.reload
      assert_equal "completed", @child.data.dig("trigger", "loop", "state")
    end

    test "skips when loop state is not pending_verification" do
      @child.data["trigger"]["loop"]["state"] = "running"
      @child.save!

      TriggerLoopVerifyJob.perform_now(@task.id)

      @child.reload
      assert_equal "running", @child.data.dig("trigger", "loop", "state")
    end

    test "accepts DONE when no verifier agent available" do
      CreativeShare.where(creative: @parent, user: @ai_bot).destroy_all

      TriggerLoopVerifyJob.perform_now(@task.id)

      @child.reload
      assert_equal "completed", @child.data.dig("trigger", "loop", "state")
    end

    test "prefers a different AI agent for verification" do
      ai_bot2 = users(:two)
      ai_bot2.update_columns(llm_vendor: "google", llm_model: "gemini-2.0-flash")
      CreativeShare.create!(creative: @parent, user: ai_bot2, permission: :feedback)

      selected_vendor = nil
      factory = ->(**opts) {
        selected_vendor = opts[:vendor]
        mock_ai_client("VERIFIED")
      }

      AiClient.stub(:new, factory) do
        TriggerLoopVerifyJob.perform_now(@task.id)
      end

      # Should have used ai_bot2 (different from task agent ai_bot)
      assert_equal "google", selected_vendor
    end

    test "falls back to task agent when no other AI agent exists" do
      selected_vendor = nil
      factory = ->(**opts) {
        selected_vendor = opts[:vendor]
        mock_ai_client("VERIFIED")
      }

      AiClient.stub(:new, factory) do
        TriggerLoopVerifyJob.perform_now(@task.id)
      end

      # Only ai_bot exists, so it should be used
      assert_equal @ai_bot.llm_vendor, selected_vendor
    end

    test "transitions to max_reached when verification fails at last iteration" do
      @child.data["trigger"]["loop"]["current_iteration"] = 9
      @child.data["trigger"]["loop"]["max_iterations"] = 10
      @child.save!

      mock_client = mock_ai_client("INCOMPLETE: PR not created")

      AiClient.stub(:new, mock_client) do
        TriggerLoopVerifyJob.perform_now(@task.id)
      end

      @child.reload
      assert_equal "max_reached", @child.data.dig("trigger", "loop", "state")
    end

    private

    def mock_ai_client(response_text)
      obj = Object.new
      obj.define_singleton_method(:chat) do |messages, &block|
        block&.call(response_text)
        response_text
      end
      obj
    end
  end
end
