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
      Creative.rebuild!

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

    test "evaluator usage inherits causal requesters and uses evaluator ownership" do
      verifier = users(:two)
      verifier.update!(llm_vendor: "google", llm_model: "test", created_by_id: users(:three).id)
      CreativeShare.create!(creative: @parent, user: verifier, permission: :feedback)
      @task.update!(usage_attribution: { "requester_ids" => [ @human.id ], "owner_id" => @human.id })
      factory = ->(**options) {
        LlmUsage::Recorder.new(context: options.fetch(:context), vendor: options[:vendor], model: options[:model]).finish
        client = Object.new
        client.define_singleton_method(:judge) { |*, **| { "answers" => { "status" => { "choice" => "VERIFIED" } } } }
        client
      }
      job = TriggerLoopVerifyJob.new
      job.stub(:pick_verifier_agent, verifier) do
        AiClient.stub(:new, factory) { job.perform(@task.id) }
      end
      usage = LlmUsage.last
      assert_equal verifier.id, usage.agent_id
      assert_equal verifier.created_by_id, usage.owner_id
      assert_equal @human.id, usage.requester_id
      assert_equal @task.id, usage.task_id
      assert_equal @child.id, usage.creative_id
      assert_equal @topic.id, usage.topic_id
      assert_equal @human.id, @task.reload.usage_attribution["owner_id"]
      assert_includes LlmUsage.visible_to(@human), usage
      assert_includes LlmUsage.visible_to(verifier.creator), usage
    end

    test "completes loop when verification returns VERIFIED" do
      mock_client = mock_ai_client("VERIFIED")

      AiClient.stub(:new, mock_client) do
        TriggerLoopVerifyJob.perform_now(@task.id)
      end

      @child.reload
      assert_equal "completed", @child.data.dig("trigger", "loop", "state")
    end

    test "native or chat AWAITING_USER verdict pauses the loop" do
      AiClient.stub(:new, mock_ai_client("AWAITING_USER")) do
        TriggerLoopVerifyJob.perform_now(@task.id)
      end
      assert_equal "awaiting_user", @child.reload.data.dig("trigger", "loop", "state")
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

    test "continues when LLM verification fails" do
      error_client = ->(**opts) {
        obj = Object.new
        obj.define_singleton_method(:judge) { |*, **| raise StandardError, "LLM API error" }
        obj
      }

      AiClient.stub(:new, error_client) do
        TriggerLoopVerifyJob.perform_now(@task.id)
      end

      @child.reload
      assert_equal "running", @child.data.dig("trigger", "loop", "state")
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

    test "verification adapter follows JSON contract for completed and awaiting work" do
      job = TriggerLoopVerifyJob.new
      %w[VERIFIED AWAITING_USER INCOMPLETE].each do |verdict|
        client = AiClient.new(vendor: "external-adapter", model: "test",
          system_prompt: TriggerLoopVerifyJob::VERIFY_SYSTEM_PROMPT)
        adapter = lambda do |messages, &block|
          prompt = JSON.parse(messages.first[:text])
          refute_match(/Respond with exactly one of|INCOMPLETE: \[list/i, prompt.fetch("input"))
          assert_includes prompt.fetch("instruction"), "Return only JSON"
          block.call({ answers: { status: { choice: verdict } }, reason: "PR not created" }.to_json)
          nil
        end
        client.stub(:chat, adapter) do
          job.stub(:decision_client, client) do
            expected = { "VERIFIED" => :verified, "AWAITING_USER" => :awaiting_user,
                         "INCOMPLETE" => "PR not created" }.fetch(verdict)
            assert_equal expected, job.send(:verify_completion, @ai_bot, "Create a PR", "Task evaluated", @task)
          end
        end
      end
    end

    test "verification schema rejection preserves JSON contract" do
      job = TriggerLoopVerifyJob.new
      client = AiClient.new(vendor: "google", model: "test",
        system_prompt: TriggerLoopVerifyJob::VERIFY_SYSTEM_PROMPT)
      rejected = Object.new
      rejected.define_singleton_method(:with_schema) { |*| }
      rejected.define_singleton_method(:ask) { |*| raise RubyLLM::BadRequestError, "response_format unsupported" }
      fallback = Object.new
      fallback.define_singleton_method(:ask) do |prompt|
        input = JSON.parse(prompt)
        raise "Conflicting format" if input.fetch("input").match?(/Respond with exactly one of|INCOMPLETE: \[list/i)
        raise "Missing JSON contract" unless input.fetch("instruction").include?("Return only JSON")

        Struct.new(:content, :tokens).new({ answers: { status: { choice: "VERIFIED" } } }.to_json, nil)
      end
      [ rejected, fallback ].each do |chat|
        chat.define_singleton_method(:messages) { [] }
        chat.define_singleton_method(:tools) { [] }
        chat.define_singleton_method(:after_message) { |*| }
      end
      chats = [ rejected, fallback ]
      client.stub(:build_conversation, -> { chats.shift }) do
        job.stub(:decision_client, client) do
          assert_equal :verified, job.send(:verify_completion, @ai_bot, "Create a PR", "PR created", @task)
        end
      end
      assert_empty chats
    end

    private

    def mock_ai_client(response_text)
      obj = Object.new
      obj.define_singleton_method(:judge) do |*, **|
        { "answers" => { "status" => { "choice" => response_text.split(":").first } }, "reason" => response_text }
      end
      obj
    end
  end
end
