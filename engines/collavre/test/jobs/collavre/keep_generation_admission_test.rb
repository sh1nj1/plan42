# frozen_string_literal: true

require "test_helper"

module Collavre
  class KeepGenerationAdmissionTest < ActiveSupport::TestCase
    setup do
      @previous_adapter = ActiveJob::Base.queue_adapter
      ActiveJob::Base.queue_adapter = :test
      @creative = creatives(:tshirt)
      @user = users(:one)
      @agent = users(:ai_bot)
      @topic = @creative.main_topic
      CreativeShare.find_or_create_by!(creative: @creative, user: @agent).update!(permission: :feedback)
      CreativeSharesCache.find_or_create_by!(creative: @creative, user: @agent, permission: :feedback)
      Orchestration::ResourceTracker.for(@agent).reset!
      @turn = @creative.comments.create!(content: "@#{@agent.name}: Continue", topic: @topic, user: @user, skip_dispatch: true)
      @config = TriggerLoopConfig.build(@topic.id, source: "keep", generation: 4, start_comment_id: @turn.id,
        current_comment_id: @turn.id, agent_id: @agent.id, cooldown_seconds: 0)
      @creative.update!(data: { "trigger" => { "keep_generation" => 4, "loop" => @config } })
      @context = @turn.reload.dispatch_payload.deep_stringify_keys
      @task = Task.create!(name: "Keep generation", agent: @agent, creative: @creative, topic_id: @topic.id,
        status: "running", trigger_event_name: "comment_created", trigger_event_payload: @context)
      @task.update_columns(status: "done")
      @reply = @creative.comments.create!(content: "[STATUS: DONE]", topic: @topic, user: @agent, task: @task, skip_dispatch: true)
      clear_enqueued_jobs
    end

    teardown do
      ActiveJob::Base.queue_adapter = @previous_adapter
    end

    %i[enqueue job_start promoted_task task_creation restoration check verify login_schedule login_execution controls].each do |entry|
      test "stale generation has no execution or loop side effects at #{entry}" do
        prepare_entry(entry)
        # Deliberately reuse every old tuple field: only generation changes.
        @creative.update!(data: @creative.reload.data.deep_merge("trigger" => {
          "keep_generation" => 5, "loop" => { "generation" => 5 }
        }))
        before = @creative.reload.data.deep_dup
        before_comments = @creative.comments.count
        clear_enqueued_jobs
        assert_no_difference "Task.count" do
          AiAgentService.stub(:new, ->(*) { flunk "Stale generation reached provider execution" }) do
            AiClient.stub(:new, ->(*) { flunk "Stale generation reached an evaluator" }) { attempt_entry(entry) }
          end
        end
        assert_equal before, @creative.reload.data
        assert_equal before_comments, @creative.comments.count
        assert_empty enqueued_jobs.select { |job| [ AiAgentJob, TriggerLoopVerifyJob, InlineAgentReplayJob ].include?(job[:job]) }
      end
    end

    test "duplicate check cannot evaluate the previous task between continuation turns" do
      @creative.update!(data: @creative.data.deep_merge("trigger" => { "loop" => {
        "current_comment_id" => nil, "current_iteration" => 2, "max_iterations" => 3
      } }))
      before = @creative.reload.data.deep_dup
      # Internal continuation snapshot checks still admit the nil anchor.
      assert KeepLoop.admit!(@creative, generation: 4, comment_id: nil)
      refute KeepLoop.task?(@creative, @task)
      AiClient.stub(:new, ->(*) { flunk "Previous turn evaluated during continuation gap" }) do
        TriggerLoopCheckJob.perform_now(@task.id)
      end
      assert_equal before, @creative.reload.data
      assert_empty enqueued_jobs.select { |job| job[:job] == TriggerLoopVerifyJob }
    end

    test "admission rejects legacy malformed absent and wrong-turn identities" do
      [ nil, false, 0, -1, "4", 3, { "start_comment_id" => @turn.id } ].each do |generation|
        refute KeepLoop.admit!(@creative, generation: generation, comment_id: @turn.id)
      end
      refute KeepLoop.admit!(@creative, generation: 4, comment_id: @turn.id + 1)
      assert KeepLoop.admit!(@creative, generation: 4, comment_id: @turn.id)
      @context["comment"].delete("keep_loop_generation")
      assert_equal :rejected, Orchestration::KeepDispatchAdmission.call(@context, @agent) { flunk "Missing identity admitted" }
      @creative.update!(data: {})
      refute KeepLoop.admit!(@creative, generation: 4, comment_id: @turn.id)
    end

    test "stale reservation cannot replace or release a current same-anchor reservation" do
      Orchestration::KeepQueuedDispatches.reserve!(@context, @agent)
      before = @creative.reload.data.deep_dup
      stale = @context.deep_merge("comment" => { "keep_loop_generation" => 3 })
      Orchestration::KeepQueuedDispatches.reserve!(stale, @agent)
      Orchestration::KeepQueuedDispatches.release!(stale, @agent)
      assert_equal before, @creative.reload.data
      assert Orchestration::KeepQueuedDispatches.pending?(@creative, @turn.id)
    end

    test "pause resume restart and loop deletion never reuse a generation" do
      original = @context.deep_dup
      %w[pause resume].each do |action|
        previous = @creative.reload.data.dig("trigger", "loop", "generation")
        SystemEvents::Dispatcher.stub(:dispatch, [ @agent ]) do
          assert Creatives::TriggerActionCommand.new(creative: @creative, user: @user, action: action).call.success?
        end
        assert_operator @creative.reload.data.dig("trigger", "loop", "generation"), :>, previous
      end
      refute KeepLoop.admit!(@creative, generation: original.dig("comment", "keep_loop_generation"), comment_id: @turn.id)
      @creative.update!(data: @creative.data.deep_merge("trigger" => { "loop" => { "state" => "completed" } }))
      previous = @creative.data.dig("trigger", "loop", "generation")
      SystemEvents::Dispatcher.stub(:dispatch, [ @agent ]) do
        Creatives::TriggerActionCommand.new(creative: @creative, user: @user, action: "restart").call
      end
      assert_operator @creative.reload.data.dig("trigger", "loop", "generation"), :>, previous
      previous = @creative.data.dig("trigger", "keep_generation")
      @creative.comments.find(@creative.data.dig("trigger", "loop", "current_comment_id")).destroy!
      assert_nil @creative.reload.data.dig("trigger", "loop")
      fresh = @creative.comments.build(content: "/keep Continue", topic: @topic, user: @user, skip_dispatch: true)
      assert_nil Comments::KeepCommand.new(comment: fresh, user: @user).call
      fresh.save!
      assert_operator @creative.reload.data.dig("trigger", "loop", "generation"), :>, previous
    end

    test "legacy loops recover through resume with a fresh integer generation" do
      @creative.update!(data: @creative.data.deep_merge("trigger" => { "loop" => { "generation" => nil, "state" => "paused" } }))
      SystemEvents::Dispatcher.stub(:dispatch, [ @agent ]) do
        Creatives::TriggerActionCommand.new(creative: @creative, user: @user, action: "resume").call
      end
      assert_equal 5, @creative.reload.data.dig("trigger", "loop", "generation")
    end

    test "an inline backend cannot permanently own an orphaned generation" do
      AiAgentJob.stub(:queue_adapter, ActiveJob::QueueAdapters::InlineAdapter.new) do
        travel 16.minutes do
          KeepLoopReconcileJob.perform_now
          assert_equal "awaiting_user", @creative.reload.data.dig("trigger", "loop", "state")
          assert_equal 4, @creative.data.dig("trigger", "loop", "generation")
        end
      end
    end

    private

    def prepare_entry(entry)
      case entry
      when :promoted_task then @task.update_columns(status: "queued")
      when :restoration
        anchor = @creative.comments.create!(content: "Covering", topic: @topic, user: @user, skip_dispatch: true)
        @task.update_columns(status: "running", trigger_event_payload: anchor.dispatch_payload.deep_stringify_keys)
        assert Orchestration::DeliveryRecord.claim_drop!(@task, @turn.id, context: @context)
        @task.update_columns(status: "failed")
      when :verify
        @creative.update!(data: @creative.data.deep_merge("trigger" => { "loop" => { "state" => "pending_verification" } }))
      when :controls
        @control = Creatives::TriggerActionCommand.new(creative: Creative.find(@creative.id), user: @user, action: "pause")
      when :login_schedule, :login_execution
        prepare_login
        @task.update_columns(trigger_event_payload: @task.trigger_event_payload.deep_merge("engine_login" => { "resumed" => true })) if entry == :login_execution
      end
    end

    def attempt_entry(entry)
      case entry
      when :enqueue then SystemEvents::Dispatcher.dispatch("comment_created", @context)
      when :job_start then AiAgentJob.perform_now(@agent.id, "comment_created", @context)
      when :promoted_task then AiAgentJob.perform_now(@task)
      when :task_creation
        Orchestration::KeepDispatchAdmission.call(@context, @agent) { flunk "Stale generation reached task creation" }
      when :restoration then Orchestration::DeliveryRecord.restore!(@task.reload)
      when :check then TriggerLoopCheckJob.perform_now(@task.id)
      when :verify then TriggerLoopVerifyJob.perform_now(@task.id)
      when :controls then @control.call
      when :login_schedule then CliProxy::InlineLogin.new(@reply, @user).resume!
      when :login_execution then InlineAgentReplayJob.perform_now(@reply.id, @user.id, @task.id)
      end
    rescue CliProxy::Client::Error
      raise unless entry == :login_schedule
    end

    def prepare_login
      gateway = AgentGateway.create!(owner: @user, name: "Generation proxy", base_url: "https://proxy.example.com",
        admin_key: "admin", completion_key: "completion", identity_secret: "x" * 32, workspace_mode: :per_user)
      @agent.update!(llm_vendor: "cli_proxy", llm_model: "paperclip/codex_local", created_by_id: @user.id, agent_gateway: gateway)
      workspace = AgentWorkspace.resolve!(agent: @agent, user: @user)
      @task.update_columns(trigger_event_payload: @context.merge("workspace_user_id" => @user.id,
        "engine_login" => { "engine" => "codex", "workspace_id" => workspace.id, "retryable" => true,
          "authorized" => true, "resumed" => true, "session_user_id" => @user.id }))
      @task.reload
      # Scheduling starts from an authorized card that has not claimed replay yet.
      @task.update_columns(trigger_event_payload: @task.trigger_event_payload.deep_merge("engine_login" => { "resumed" => false }))
    end
  end
end
