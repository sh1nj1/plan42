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
      @child.rebuild!

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
        user: @ai_bot, task: @task,
        skip_dispatch: true,
        created_at: @task.created_at + 1.second
      )
    end

    test "keep verification falls back to an authorized child-only task agent" do
      CreativeShare.where(creative: @parent, user: @ai_bot).destroy_all
      CreativeShare.create!(creative: @child, user: @ai_bot, permission: :feedback)
      @child.update!(data: @child.data.deep_merge("trigger" => { "loop" => { "source" => "keep", "agent_id" => @ai_bot.id } }))
      job = TriggerLoopVerifyJob.new
      selected = []
      job.stub(:verify_completion, ->(agent, *) { selected << agent.id; :awaiting_user }) { job.perform(@task.id) }
      assert_equal [ @ai_bot.id ], selected
      assert_equal "awaiting_user", @child.reload.data.dig("trigger", "loop", "state")
    end

    test "keep verification skips denied candidates and prefers an authorized alternative" do
      denied = users(:two)
      allowed = users(:three)
      [ denied, allowed ].each do |agent|
        agent.update_columns(llm_vendor: "google", llm_model: "test")
        CreativeShare.create!(creative: @parent, user: agent, permission: :feedback)
      end
      share = CreativeShare.create!(creative: @child, user: denied, permission: :feedback)
      PermissionCacheJob.perform_now(:propagate_share, creative_share_id: share.id)
      share.update_columns(permission: :no_access)
      assert @child.has_permission?(denied, :read)
      @child.update!(data: @child.data.deep_merge("trigger" => { "loop" => { "source" => "keep" } }))
      job = TriggerLoopVerifyJob.new
      selected = []
      job.stub(:verify_completion, ->(agent, *) { selected << agent.id; :awaiting_user }) do
        job.perform(@task.id)
      end
      assert_equal [ allowed.id ], selected
      assert_equal "awaiting_user", @child.reload.data.dig("trigger", "loop", "state")
    end

    test "keep verification falls back to the task agent when alternatives are denied" do
      denied = users(:two)
      denied.update_columns(llm_vendor: "google", llm_model: "test")
      CreativeShare.create!(creative: @parent, user: denied, permission: :feedback)
      CreativeShare.create!(creative: @child, user: denied, permission: :no_access)
      @child.update!(data: @child.data.deep_merge("trigger" => { "loop" => { "source" => "keep" } }))
      job = TriggerLoopVerifyJob.new
      selected = []
      job.stub(:verify_completion, ->(agent, *) { selected << agent.id; :awaiting_user }) do
        job.perform(@task.id)
      end
      assert_equal [ @ai_bot.id ], selected
      assert_equal "awaiting_user", @child.reload.data.dig("trigger", "loop", "state")
    end

    test "keep evaluator never sends loop content to a denied or revoked verifier" do
      share = CreativeShare.create!(creative: @child, user: @ai_bot, permission: :feedback)
      CreativeShare.create!(creative: @child, user: nil, permission: :read)
      PermissionCacheJob.perform_now(:propagate_share, creative_share_id: share.id)
      assert @child.has_permission?(@ai_bot, :read)
      share.update_columns(permission: :no_access)
      assert @child.has_permission?(@ai_bot, :read), "Cached grant must remain stale for this regression"
      data = @child.data.deep_dup
      data["trigger"]["loop"].merge!("source" => "keep", "goal" => "Private keep goal")
      @child.update!(data: data)
      job = TriggerLoopVerifyJob.new
      AiClient.stub(:new, ->(*) { flunk "Denied verifier received loop content" }) do
        job.perform(@task.id)
      end
      assert_equal "completed", @child.reload.data.dig("trigger", "loop", "state")
    end

    test "keep evaluator filters context by the selected verifier current read permission" do
      verifier = users(:two)
      CreativeShare.create!(creative: @child, user: verifier, permission: :feedback)
      visible = Creative.create!(description: "Visible context instructions", user: @human)
      hidden = Creative.create!(description: "Private context secret", user: @human)
      revoked = Creative.create!(description: "Revoked context secret", user: @human)
      CreativeShare.create!(creative: visible, user: verifier, permission: :read)
      share = CreativeShare.create!(creative: revoked, user: verifier, permission: :read)
      CreativeShare.create!(creative: revoked, user: nil, permission: :read)
      PermissionCacheJob.perform_now(:propagate_share, creative_share_id: share.id)
      # Emulate revocation before the asynchronous cache invalidation runs.
      share.update_columns(permission: :no_access)
      assert revoked.has_permission?(verifier, :read), "The asynchronous cache still grants the revoked share"
      @parent.update!(data: @parent.data.merge("context_ids" => [ visible.id, hidden.id ]))
      data = @child.data.deep_dup
      data["context_ids"] = [ visible.id, revoked.id ]
      data["trigger"]["loop"].merge!("source" => "keep", "goal" => "Keep goal")
      @child.update!(data: data)
      client = Object.new
      check_prompt = ->(messages) {
        prompt = messages.first.fetch(:text)
        assert_includes prompt, visible.description
        assert_equal 1, prompt.scan(visible.description).size
        assert_includes prompt, "Keep goal"
        refute_includes prompt, hidden.description
        refute_includes prompt, revoked.description
      }
      client.define_singleton_method(:judge) do |prompt, **|
        check_prompt.call([ { text: prompt } ])
        { "answers" => { "status" => { "choice" => "VERIFIED" } } }
      end
      job = TriggerLoopVerifyJob.new
      job.stub(:pick_verifier_agent, verifier) do
        AiClient.stub(:new, client) { job.perform(@task.id) }
      end
      assert_equal "completed", @child.reload.data.dig("trigger", "loop", "state")
    end

    test "failed verification continuation dispatch preserves the retryable verification turn" do
      data = @child.data.deep_dup
      data["trigger"]["loop"].merge!("source" => "keep", "current_comment_id" => 999)
      @child.update!(data: data)
      original = @child.reload.data.dig("trigger", "loop").deep_dup
      job = TriggerLoopVerifyJob.new
      job.stub(:pick_verifier_agent, @ai_bot) do
        job.stub(:verify_completion, "INCOMPLETE") do
          SystemEvents::Dispatcher.stub(:dispatch, ->(*) { raise "dispatch unavailable" }) do
            assert_no_difference -> { @child.comments.count } do
              assert_raises(RuntimeError) { job.perform(@task.id) }
            end
          end
          assert_equal original.except("control_version"), @child.reload.data.dig("trigger", "loop").except("control_version")
          SystemEvents::Dispatcher.stub(:dispatch, [ @ai_bot ]) { job.perform(@task.id) }
        end
      end
      assert_equal "running", @child.reload.data.dig("trigger", "loop", "state")
      assert_equal 2, @child.data.dig("trigger", "loop", "current_iteration")
    end

    test "verification uses the task reply instead of a newer same-agent comment" do
      @child.comments.create!(content: "Unrelated [STATUS: DONE]", topic: @topic, user: @ai_bot, skip_dispatch: true)
      job = TriggerLoopVerifyJob.new
      job.stub(:pick_verifier_agent, @ai_bot) do
        job.stub(:verify_completion, ->(_verifier, _instructions, response, task) {
          assert_equal @task, task
          assert_equal @agent_comment.content, response
          :verified
        }) { job.perform(@task.id) }
      end
      assert_equal "completed", @child.reload.data.dig("trigger", "loop", "state")
    end

    test "pause after failed verification transition prevents the next turn" do
      data = @child.data.deep_dup
      data["trigger"]["loop"]["source"] = "keep"
      @child.update!(data: data)
      job = TriggerLoopVerifyJob.new
      original = job.method(:continuation_agent)
      job.stub(:pick_verifier_agent, @ai_bot) do
        job.stub(:verify_completion, "INCOMPLETE") do
          job.stub(:continuation_agent, ->(creative, topic) {
            Creatives::TriggerActionCommand.new(creative: creative, user: @human, action: "pause").call
            original.call(creative, topic)
          }) do
            SystemEvents::Dispatcher.stub(:dispatch, ->(*) { flunk "paused verification dispatched" }) do
              assert_no_difference -> { @child.comments.count } do
                job.perform(@task.id)
              end
            end
          end
        end
      end
      assert_equal "paused", @child.reload.data.dig("trigger", "loop", "state")
    end

    test "verification ignores a task outside the current keep turn" do
      data = @child.data.deep_dup
      data["trigger"]["loop"].merge!("source" => "keep", "start_comment_id" => 900, "current_comment_id" => 1000)
      @child.update!(data: data)
      TriggerLoopVerifyJob.perform_now(@task.id)
      assert_equal "pending_verification", @child.reload.data.dig("trigger", "loop", "state")
    end

    test "verification results cannot overwrite a user pause" do
      [ :verified, :awaiting_user, "INCOMPLETE" ].each do |result|
        data = @child.reload.data.deep_dup
        data["trigger"]["loop"]["state"] = "pending_verification"
        @child.update!(data: data)
        job = TriggerLoopVerifyJob.new
        job.stub(:pick_verifier_agent, @ai_bot) do
          job.stub(:verify_completion, ->(*) {
            Creatives::TriggerActionCommand.new(creative: @child.reload, user: @human, action: "pause").call
            result
          }) do
            assert_no_difference -> { @child.comments.count } do
              job.perform(@task.id)
            end
          end
        end
        assert_equal "paused", @child.reload.data.dig("trigger", "loop", "state")
      end
    end

    test "failed verification does not reroute an unavailable selected agent" do
      data = @child.data.deep_dup
      data["trigger"]["loop"].merge!("source" => "keep", "agent_id" => -1)
      @child.update!(data: data)
      job = TriggerLoopVerifyJob.new
      job.stub(:pick_verifier_agent, @ai_bot) do
        job.stub(:verify_completion, "INCOMPLETE") { job.perform(@task.id) }
      end
      assert_equal "awaiting_user", @child.reload.data.dig("trigger", "loop", "state")
      assert_nil @child.comments.order(:id).last.user_id
    end

    test "verification abandons a superseded generation" do
      job = TriggerLoopVerifyJob.new
      job.stub(:pick_verifier_agent, @ai_bot) do
        job.stub(:verify_completion, ->(*) {
          data = @child.reload.data.deep_dup
          data["trigger"]["loop"].merge!("source" => "keep", "start_comment_id" => 1000, "state" => "running")
          @child.update!(data: data)
          :verified
        }) { job.perform(@task.id) }
      end
      assert_equal "running", @child.reload.data.dig("trigger", "loop", "state")
    end

    test "keep without a goal inherits the drop container instructions in both evaluators" do
      instruction = Creative.create!(description: "Stage acceptance instructions", user: @human)
      CreativeShare.create!(creative: instruction, user: @ai_bot, permission: :read)
      @parent.update!(data: @parent.data.merge("context_ids" => [ instruction.id ]))
      data = @child.data.deep_dup
      data["trigger"]["loop"].merge!("source" => "keep", "goal" => "")
      @child.update!(data: data)
      assert_equal @parent, @child.trigger_loop_context
      verifier = TriggerLoopVerifyJob.new
      verifier.stub(:verify_completion, ->(_agent, instructions, *_args) {
        assert_includes instructions, instruction.description
        :verified
      }) do
        verifier.perform(@task.id)
      end
      assert_equal "completed", @child.reload.data.dig("trigger", "loop", "state")
      instructions = TriggerLoopCheckJob.new.send(:collect_fallback_instructions, @child, @child.trigger_loop_context, @ai_bot)
      assert_includes instructions, instruction.description
    end

    test "drop verification failure without an agent does not post a comment" do
      assert_no_difference -> { @child.comments.count } do
        TriggerLoopVerifyJob.new.send(:post_verification_failed, @child, @topic, nil, 2, 10, "Incomplete")
      end
    end

    test "keep verifier receives goal and retries without forcing the previous agent" do
      data = @child.data.deep_dup
      data["trigger"]["loop"].merge!("source" => "keep", "goal" => "Deliver keep")
      @child.update!(data: data)
      job = TriggerLoopVerifyJob.new
      assert_includes job.send(:collect_instructions, @child, @child, @ai_bot), "Deliver keep"
      job.send(:post_verification_failed, @child, @topic, @ai_bot, 2, 10, "Missing tests")
      refute_match(/@/, @child.comments.order(:id).last.content)
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

    test "native incomplete explanation filters contexts for the chat agent" do
      verifier = users(:two)
      verifier.update!(llm_vendor: "typesafe", llm_model: "test")
      CreativeShare.create!(creative: @parent, user: verifier, permission: :feedback)
      visible = Creative.create!(description: "Shared acceptance criteria", user: @human)
      secret = Creative.create!(description: "Verifier-only confidential instructions", user: @human)
      CreativeShare.create!(creative: visible, user: @ai_bot, permission: :read)
      CreativeShare.create!(creative: visible, user: verifier, permission: :read)
      CreativeShare.create!(creative: secret, user: verifier, permission: :read)
      @parent.update!(data: @parent.data.merge("context_ids" => [ visible.id, secret.id ]))
      native_prompts = []
      explanation_prompts = []
      native = Object.new
      native.define_singleton_method(:judge) do |prompt, **|
        native_prompts << prompt
        { "source" => "judge", "answers" => { "status" => { "choice" => "INCOMPLETE" } } }
      end
      chat = Object.new
      chat.define_singleton_method(:chat) do |messages|
        explanation_prompts << messages.first.fetch(:text)
        "Acceptance criteria remain"
      end
      factory = ->(**options) { options.fetch(:vendor) == "typesafe" ? native : chat }
      AiClient.stub(:new, factory) { TriggerLoopVerifyJob.perform_now(@task.id) }

      assert_equal 1, native_prompts.size
      assert_includes native_prompts.first, secret.description
      assert_equal 1, explanation_prompts.size
      assert_includes explanation_prompts.first, visible.description
      assert_includes explanation_prompts.first, @child.description
      assert_includes explanation_prompts.first, @agent_comment.content
      refute_includes explanation_prompts.first, secret.description
      assert_includes @child.comments.order(:id).last.content, "Acceptance criteria remain"
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
