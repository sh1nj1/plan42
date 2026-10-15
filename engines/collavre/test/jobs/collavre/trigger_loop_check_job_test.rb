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
      @child.rebuild!

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

    test "rejected restoration releases the current keep turn and is not swept again" do
      [ :permission, :scheduler, :missing_decision ].each do |reason|
        turn = @child.comments.create!(content: "Keep working", user: @human, topic: @topic, skip_dispatch: true)
        config = TriggerLoopConfig.build(@topic.id, source: "keep", current_comment_id: turn.id, start_comment_id: turn.id)
        @child.update!(data: { "trigger" => { "loop" => config } })
        record = Orchestration::DeliveryRecord
        payload = turn.dispatch_payload.deep_stringify_keys
        payload["comment"]["id"] = turn.id - 1
        payload[record::DROPPED_KEY] = [ turn.id ]
        Task.where(id: @task.id).update_all(status: "running", trigger_event_payload: payload)
        scheduler = Object.new
        scheduler.define_singleton_method(:schedule) { |_| reason == :missing_decision ? [] : [ { timing: :rejected, reason: :quota } ] }
        Orchestration::Matcher.stub(:permits_creative_access?, reason != :permission) do
          Orchestration::Scheduler.stub(:new, scheduler) do
            AiAgentJob.stub(:perform_later, ->(*) { flunk "Rejected restoration was enqueued" }) do
              @task.reload.update!(status: "failed")
            end
          end
        end
        recovered = @child.reload.data.dig("trigger", "loop")
        assert_equal "awaiting_user", recovered["state"], reason.to_s
        assert_equal config["current_iteration"], recovered["current_iteration"]
        refute record.pending_restoration?(@task.reload, comment_id: turn.id)
        AiAgentJob.stub(:perform_later, ->(*) { flunk "Rejected restoration was swept again" }) { record.restore!(@task.reload) }
      end
    end

    test "rejected restoration preserves another pending owner of the same keep turn" do
      [ true, false ].each do |admitted|
        turn = @child.comments.create!(content: "Keep working", user: @human, topic: @topic, skip_dispatch: true)
        config = TriggerLoopConfig.build(@topic.id, source: "keep", current_comment_id: turn.id, start_comment_id: turn.id, cooldown_seconds: 0)
        @child.update!(data: { "trigger" => { "loop" => config } })
        record = Orchestration::DeliveryRecord
        payload = turn.dispatch_payload.deep_stringify_keys
        payload["comment"]["id"] = turn.id - 1
        payload[record::DROPPED_KEY] = [ turn.id ]
        Task.where(id: @task.id).update_all(status: "failed", trigger_event_payload: payload)
        other = Task.create!(name: "Other covering turn", status: "running", agent: users(:two), creative: @child,
          topic_id: @topic.id, trigger_event_name: "comment_created", trigger_event_payload: payload)
        other_payload = admitted ? payload.merge(record::RESTORED_KEY => [ turn.id ]) : payload
        other.update_columns(status: "failed", trigger_event_payload: other_payload)
        record.reject_restore!(@task.reload, turn.id)
        assert_equal "running", @child.reload.data.dig("trigger", "loop", "state")
        if admitted
          restored = Task.create!(name: "Restored turn", status: "running", agent: other.agent, creative: @child,
            topic_id: @topic.id, trigger_event_name: "comment_created", trigger_event_payload: turn.dispatch_payload.deep_stringify_keys)
          @child.comments.create!(content: "[STATUS: BLOCKED]", user: other.agent, task: restored, topic: @topic, skip_dispatch: true)
          TriggerLoopCheckJob.stub(:perform_later, ->(*) { true }) { restored.update!(status: "done") }
          TriggerLoopCheckJob.perform_now(restored.id)
        else
          record.reject_restore!(other.reload, turn.id)
        end
        assert_equal "awaiting_user", @child.reload.data.dig("trigger", "loop", "state")
        other.destroy!
      end
    end

    test "verification enqueue recovery preserves a newer control snapshot" do
      [ { "state" => "paused" }, { "start_comment_id" => 1000 } ].each do |change|
        config = TriggerLoopConfig.build(@topic.id, source: "keep", current_comment_id: 999, start_comment_id: 999)
        @child.update!(data: { "trigger" => { "loop" => config } })
        @child.comments.where(task_id: @task.id).destroy_all
        @child.comments.create!(content: "[STATUS: DONE]", user: @ai_bot, task: @task, topic: @topic, skip_dispatch: true)
        replacement = nil
        enqueue = lambda do |*|
          @child.reload
          replacement = @child.data.dig("trigger", "loop").merge(change)
          @child.update!(data: { "trigger" => { "loop" => replacement } })
          raise "queue unavailable"
        end
        TriggerLoopVerifyJob.stub(:perform_later, enqueue) { assert_raises(RuntimeError) { TriggerLoopCheckJob.perform_now(@task.id) } }
        assert_equal replacement, @child.reload.data.dig("trigger", "loop")
      end
    end

    test "failed verification enqueue preserves the accepted keep turn for retry" do
      [ :raise, :reject ].each do |failure|
        config = TriggerLoopConfig.build(@topic.id, source: "keep", current_comment_id: 999, start_comment_id: 999,
          current_iteration: 2, infra_retry_count: 1)
        @child.update!(data: { "trigger" => { "loop" => config } })
        @child.comments.where(task_id: @task.id).destroy_all
        @child.comments.create!(content: "[STATUS: DONE]", user: @ai_bot, task: @task, topic: @topic, skip_dispatch: true)
        error = RuntimeError.new("queue unavailable")
        enqueue = ->(*) { failure == :raise ? (raise error) : false }
        TriggerLoopVerifyJob.stub(:perform_later, enqueue) do
          raised = assert_raises(StandardError) { TriggerLoopCheckJob.perform_now(@task.id) }
          assert_same error, raised if failure == :raise
        end
        restored = @child.reload.data.dig("trigger", "loop")
        assert_equal config.except("control_version"), restored.except("control_version")
        enqueued = []
        TriggerLoopVerifyJob.stub(:perform_later, ->(id) { enqueued << id }) { TriggerLoopCheckJob.perform_now(@task.id) }
        assert_equal [ @task.id ], enqueued
        assert_equal "pending_verification", @child.reload.data.dig("trigger", "loop", "state")
      end
    end

    test "keep fallback skips denied and revoked candidates before selecting a reader" do
      allowed = users(:two)
      allowed.update_columns(llm_vendor: "google", llm_model: "test")
      CreativeShare.create!(creative: @parent, user: allowed, permission: :feedback)
      share = CreativeShare.create!(creative: @child, user: @ai_bot, permission: :feedback)
      PermissionCacheJob.perform_now(:propagate_share, creative_share_id: share.id)
      share.update_columns(permission: :no_access)
      assert @child.has_permission?(@ai_bot, :read)
      @child.update!(data: @child.data.deep_merge("trigger" => { "loop" => { "source" => "keep" } }))
      @child.comments.create!(content: "Work needs input", user: @ai_bot, task: @task, topic: @topic, skip_dispatch: true)
      selected = []
      client = Object.new
      client.define_singleton_method(:judge) { |*, **| { "answers" => { "status" => { "choice" => "BLOCKED" } } } }
      AiClient.stub(:new, ->(**options) { selected << options.fetch(:context).fetch(:user).id; client }) do
        TriggerLoopCheckJob.perform_now(@task.id)
      end
      assert_equal [ allowed.id ], selected
      assert_equal "awaiting_user", @child.reload.data.dig("trigger", "loop", "state")
      assert_equal 0, @child.data.dig("trigger", "loop", "current_iteration")
    end

    test "deleted accepted keep replies recover both evaluation phases" do
      [ [ TriggerLoopCheckJob, "running" ], [ TriggerLoopVerifyJob, "pending_verification" ] ].each do |job, state|
        config = TriggerLoopConfig.build(@topic.id, source: "keep", state: state,
          current_comment_id: 999, start_comment_id: 999, cooldown_seconds: 15)
        @child.update!(data: { "trigger" => { "loop" => config } })
        reply = @child.comments.create!(content: "[STATUS: DONE]", user: @ai_bot, task: @task, topic: @topic, skip_dispatch: true)
        reply.destroy!
        @child.comments.create!(content: "[STATUS: DONE]", user: @ai_bot, topic: @topic, skip_dispatch: true)
        AiClient.stub(:new, ->(*) { flunk "Missing response must not be evaluated" }) { job.perform_now(@task.id) }
        recovered = @child.reload.data.dig("trigger", "loop")
        assert_equal "awaiting_user", recovered["state"]
        assert_equal 999, recovered["current_comment_id"]
        assert_equal config["current_iteration"], recovered["current_iteration"]
        assert_operator recovered["control_version"], :>, config.fetch("control_version", 0)
      end
    end

    test "dropped current keep dispatch retains ownership until restored work completes" do
      share = CreativeShare.create!(creative: @child, user: @ai_bot, permission: :feedback)
      PermissionCacheJob.perform_now(:propagate_share, creative_share_id: share.id)
      turn = @child.comments.create!(content: "Keep working", user: @human, topic: @topic, skip_dispatch: true)
      config = TriggerLoopConfig.build(@topic.id, source: "keep", current_comment_id: turn.id, start_comment_id: turn.id, cooldown_seconds: 0)
      @child.update!(data: { "trigger" => { "loop" => config } })
      record = Orchestration::DeliveryRecord
      payload = turn.dispatch_payload.deep_stringify_keys
      payload["comment"]["id"] = turn.id - 1
      payload[record::DROPPED_KEY] = [ turn.id ]
      payload[record::KEY] = [ turn.id ]
      Task.where(id: @task.id).update_all(status: "running", trigger_event_payload: payload)
      enqueued = []
      AiAgentJob.stub(:perform_later, ->(*args) { enqueued << args }) { @task.reload.update!(status: "failed") }
      assert_equal 1, enqueued.size
      assert_equal "running", @child.reload.data.dig("trigger", "loop", "state")
      assert_includes record.restored_ids_in(@task.reload.trigger_event_payload), turn.id
      restored = Task.create!(name: "Restored keep", status: "running", agent: @ai_bot, creative: @child,
        topic_id: @topic.id, trigger_event_name: "comment_created", trigger_event_payload: turn.dispatch_payload.deep_stringify_keys)
      @child.comments.create!(content: "[STATUS: BLOCKED]", user: @ai_bot, task: restored, topic: @topic, skip_dispatch: true)
      checks = []
      TriggerLoopCheckJob.stub(:perform_later, ->(id) { checks << id }) { restored.update!(status: "done") }
      assert_equal [ restored.id ], checks
      TriggerLoopCheckJob.perform_now(restored.id)
      assert_equal "awaiting_user", @child.reload.data.dig("trigger", "loop", "state")
    end

    test "settled handoff releases keep ownership that was waiting for restoration" do
      turn = @child.comments.create!(content: "Keep working", user: @human, topic: @topic, skip_dispatch: true)
      config = TriggerLoopConfig.build(@topic.id, source: "keep", current_comment_id: turn.id)
      @child.update!(data: { "trigger" => { "loop" => config } })
      payload = { "comment" => { "id" => turn.id - 1 }, Orchestration::DeliveryRecord::KEY => [ turn.id ],
                  Orchestration::DeliveryRecord::DROPPED_KEY => [ turn.id ] }
      Task.where(id: @task.id).update_all(status: "running", trigger_event_payload: payload)
      @task.reload.update!(status: "cancelled")
      assert_equal "running", @child.reload.data.dig("trigger", "loop", "state")
      Orchestration::DeliveryRecord.mark_handed_off!(@task)
      assert_equal "awaiting_user", @child.reload.data.dig("trigger", "loop", "state")
    end

    test "restoration of another dropped comment does not retain the current keep turn" do
      turn = @child.comments.create!(content: "Keep working", user: @human, topic: @topic, skip_dispatch: true)
      config = TriggerLoopConfig.build(@topic.id, source: "keep", current_comment_id: 999)
      @child.update!(data: { "trigger" => { "loop" => config } })
      payload = { "comment" => { "id" => 999 }, Orchestration::DeliveryRecord::DROPPED_KEY => [ turn.id ] }
      Task.where(id: @task.id).update_all(status: "running", trigger_event_payload: payload)
      @task.reload.update!(status: "cancelled")
      assert_equal "awaiting_user", @child.reload.data.dig("trigger", "loop", "state")
    end

    test "missing reply recovery preserves paused replacement and drop loops" do
      [ { "state" => "paused" }, { "current_comment_id" => 1000 }, { "source" => "drop" } ].each do |change|
        config = TriggerLoopConfig.build(@topic.id, source: "keep", current_comment_id: 999).merge(change)
        @child.update!(data: { "trigger" => { "loop" => config } })
        TriggerLoopCheckJob.perform_now(@task.id)
        assert_equal config, @child.reload.data.dig("trigger", "loop")
      end
    end

    test "keep fallback evaluates with the authorized child-only task agent" do
      CreativeShare.where(creative: @parent, user: @ai_bot).destroy_all
      CreativeShare.create!(creative: @child, user: @ai_bot, permission: :feedback)
      @child.update!(data: @child.data.deep_merge("trigger" => { "loop" => { "source" => "keep", "agent_id" => @ai_bot.id } }))
      @child.comments.create!(content: "Work needs your input", user: @ai_bot, task: @task, topic: @topic, skip_dispatch: true)
      selected = []
      client = Object.new
      client.define_singleton_method(:judge) { |*, **| { "answers" => { "status" => { "choice" => "BLOCKED" } } } }
      AiClient.stub(:new, ->(**options) { selected << options.fetch(:context).fetch(:user).id; client }) do
        TriggerLoopCheckJob.perform_now(@task.id)
      end
      assert_equal [ @ai_bot.id ], selected
      assert_equal "awaiting_user", @child.reload.data.dig("trigger", "loop", "state")
    end

    test "task fallback preserves alternative priority current permission and drop behavior" do
      CreativeShare.where(creative: @parent, user: @ai_bot).destroy_all
      share = CreativeShare.create!(creative: @child, user: @ai_bot, permission: :feedback)
      job = TriggerLoopCheckJob.new
      assert_nil job.send(:pick_fallback_agent, @parent, @child, @ai_bot.id)
      @child.update!(data: @child.data.deep_merge("trigger" => { "loop" => { "source" => "keep" } }))
      assert_equal @ai_bot, job.send(:pick_fallback_agent, @parent, @child, @ai_bot.id)
      other = users(:two)
      other.update_columns(llm_vendor: "google", llm_model: "test")
      CreativeShare.create!(creative: @child, user: other, permission: :read)
      @parent.stub(:all_shared_users, ->(_) { [ Struct.new(:user).new(other) ] }) do
        assert_equal other, job.send(:pick_fallback_agent, @parent, @child, @ai_bot.id)
      end
      PermissionCacheJob.perform_now(:propagate_share, creative_share_id: share.id)
      share.update_columns(permission: :no_access)
      assert @child.has_permission?(@ai_bot, :read)
      assert_nil job.send(:pick_fallback_agent, @parent, @child, @ai_bot.id)
      assert_nil job.send(:pick_fallback_agent, @parent, @child, -1)
    end

    test "fallback write pool also excludes agents denied on the loop creative" do
      allowed = users(:two)
      allowed.update_columns(llm_vendor: "google", llm_model: "test")
      CreativeShare.create!(creative: @child, user: allowed, permission: :read)
      CreativeShare.create!(creative: @child, user: @ai_bot, permission: :no_access)
      shares = [ Struct.new(:user).new(@ai_bot), Struct.new(:user).new(allowed) ]
      @parent.stub(:all_shared_users, ->(permission) { permission == :write ? shares : [] }) do
        assert_equal allowed, TriggerLoopCheckJob.new.send(:pick_fallback_agent, @parent, @child)
      end
    end

    test "missing reply recovery does not overwrite a concurrent pause or replacement" do
      [ { "state" => "paused" }, { "start_comment_id" => 1000 } ].each do |change|
        config = TriggerLoopConfig.build(@topic.id, source: "keep", current_comment_id: 999, start_comment_id: 999)
        @child.update!(data: { "trigger" => { "loop" => config } })
        job = TriggerLoopCheckJob.new
        lookup = job.method(:find_last_agent_comment)
        job.stub(:find_last_agent_comment, ->(creative, topic, task) {
          newer = @child.reload.data.deep_dup
          newer["trigger"]["loop"].merge!(change)
          @child.update!(data: newer)
          lookup.call(creative, topic, task)
        }) { job.perform(@task.id) }
        assert_equal config.merge(change), @child.reload.data.dig("trigger", "loop")
      end
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
      job = TriggerLoopCheckJob.new
      AiClient.stub(:new, ->(*) { flunk "Denied verifier received loop content" }) do
        comment = @child.comments.create!(content: "Private response", user: @ai_bot, task: @task,
                                          topic: @topic, skip_dispatch: true)
        assert_equal :continue, job.send(:llm_fallback_evaluate, @child, @parent, comment, @task)
      end
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
      @child.comments.create!(content: "Finished work", user: @ai_bot, task: @task, topic: @topic, skip_dispatch: true)
      client = Object.new
      check_prompt = ->(messages) {
        prompt = messages.first.fetch(:text)
        assert_includes prompt, visible.description
        assert_equal 1, prompt.scan(visible.description).size
        assert_includes prompt, "Keep goal"
        refute_includes prompt, hidden.description
        refute_includes prompt, revoked.description
      }
      client.define_singleton_method(:chat) do |messages, &block|
        check_prompt.call(messages)
        block.call("BLOCKED")
      end
      job = TriggerLoopCheckJob.new
      job.stub(:pick_fallback_agent, verifier) do
        AiClient.stub(:new, client) { job.perform(@task.id) }
      end
      assert_equal "awaiting_user", @child.reload.data.dig("trigger", "loop", "state")
    end

    test "rejected continuation enqueue restores the accepted keep turn" do
      CreativeShare.create!(creative: @child, user: @ai_bot, permission: :feedback)
      data = @child.data.deep_dup
      data["trigger"]["loop"].merge!("source" => "keep", "agent_id" => @ai_bot.id,
        "current_comment_id" => 999, "start_comment_id" => 999)
      @child.update!(data: data)
      @child.comments.create!(content: "[STATUS: CONTINUE]", user: @ai_bot, task: @task, topic: @topic, skip_dispatch: true)
      before = @child.reload.data.dig("trigger", "loop").deep_dup
      AiAgentJob.stub(:perform_later, false) do
        assert_raises(ActiveJob::EnqueueError) { TriggerLoopCheckJob.perform_now(@task.id) }
      end
      assert_equal before.except("control_version"), @child.reload.data.dig("trigger", "loop").except("control_version")
    end

    test "failed continuation and infrastructure dispatch preserve the retryable keep turn" do
      [ "[STATUS: CONTINUE]", "Connection timed out" ].each do |response|
        data = @child.reload.data.deep_dup
        data["trigger"]["loop"].merge!("source" => "keep", "current_comment_id" => 999,
          "start_comment_id" => 999, "current_iteration" => 0, "infra_retry_count" => 0)
        @child.update!(data: data)
        @child.comments.create!(content: response, user: @ai_bot, task: @task, topic: @topic, skip_dispatch: true)
        original = @child.reload.data.dig("trigger", "loop").deep_dup
        error = RuntimeError.new("dispatch unavailable")
        SystemEvents::Dispatcher.stub(:dispatch, ->(*) { raise error }) do
          assert_no_difference -> { @child.comments.count } do
            assert_same error, assert_raises(RuntimeError) { TriggerLoopCheckJob.perform_now(@task.id) }
          end
        end
        restored = @child.reload.data.dig("trigger", "loop")
        assert_equal original.except("control_version"), restored.except("control_version")
        SystemEvents::Dispatcher.stub(:dispatch, [ @ai_bot ]) { TriggerLoopCheckJob.perform_now(@task.id) }
        assert_equal "running", @child.reload.data.dig("trigger", "loop", "state")
        refute_equal 999, @child.data.dig("trigger", "loop", "current_comment_id")
      end
    end

    test "blank finalized keep response releases the current turn without evaluation" do
      turn = @child.comments.create!(content: "Keep working", user: @human, topic: @topic, skip_dispatch: true)
      config = TriggerLoopConfig.build(@topic.id, source: "keep", current_comment_id: turn.id, start_comment_id: turn.id)
      @child.update!(data: { "trigger" => { "loop" => config } })
      @task.update_columns(status: "running", trigger_event_payload: { "comment" => { "id" => turn.id } })
      placeholder = @child.comments.create!(content: "Thinking", user: @ai_bot, task: @task, topic: @topic, skip_dispatch: true)
      assert_nil AiAgent::ResponseFinalizer.new(task: @task, agent: @ai_bot, original_comment: turn,
        reply_comment: placeholder, response_content: "  ").finalize
      assert_not Comment.exists?(placeholder.id)
      TriggerLoopCheckJob.stub(:perform_later, ->(*) { flunk "Blank response must not be evaluated" }) do
        @task.reload.update!(status: "done")
      end
      recovered = @child.reload.data.dig("trigger", "loop")
      assert_equal "awaiting_user", recovered["state"]
      assert_equal config["current_iteration"], recovered["current_iteration"]
      assert_operator recovered["control_version"], :>, config.fetch("control_version", 0)
    end

    test "response-less completion preserves other owners and inactive or unrelated loops" do
      [ { "source" => "drop" }, { "state" => "paused" }, { "current_comment_id" => 1000 } ].each do |change|
        config = TriggerLoopConfig.build(@topic.id, source: "keep", current_comment_id: 999).merge(change)
        @child.update!(data: { "trigger" => { "loop" => config } })
        @task.update_columns(status: "running")
        @task.reload.update!(status: "done")
        assert_equal config, @child.reload.data.dig("trigger", "loop")
      end
      config = TriggerLoopConfig.build(@topic.id, source: "keep", current_comment_id: 999)
      @child.update!(data: { "trigger" => { "loop" => config } })
      survivor = Task.create!(name: "Other owner", status: "running", agent: @ai_bot, creative: @child,
        topic_id: @topic.id, trigger_event_name: "comment_created", trigger_event_payload: { "comment" => { "id" => 999 } })
      @task.update_columns(status: "running")
      @task.reload.update!(status: "done")
      assert_equal config, @child.reload.data.dig("trigger", "loop")
      survivor.update!(status: "done")
      assert_equal "awaiting_user", @child.reload.data.dig("trigger", "loop", "state")
    end

    test "login delegation and finalized review output do not release keep ownership" do
      config = TriggerLoopConfig.build(@topic.id, source: "keep", current_comment_id: 999, cooldown_seconds: 0)
      [ { "retryable" => true }, { "replay_completed" => true }, { "replay_abandoned" => true } ].each do |login|
        @child.update!(data: { "trigger" => { "loop" => config.deep_dup } })
        @task.update_columns(status: "running", trigger_event_payload: { "comment" => { "id" => 999 }, "engine_login" => login })
        TriggerLoopCheckJob.stub(:perform_later, ->(*) { true }) { @task.reload.update!(status: "done") }
        assert_equal "running", @child.reload.data.dig("trigger", "loop", "state")
      end
      @task.update_columns(status: "running", trigger_event_payload: { "comment" => { "id" => 999 } })
      @task.task_actions.create!(action_type: "review_updated", status: "done", payload: {})
      TriggerLoopCheckJob.stub(:perform_later, ->(*) { true }) { @task.reload.update!(status: "done") }
      assert_equal "running", @child.reload.data.dig("trigger", "loop", "state")
    end

    test "terminal unsuccessful tasks release only the persisted current keep turn" do
      %w[cancelled failed escalated].each do |status|
        data = @child.reload.data.deep_dup
        data["trigger"]["loop"].merge!("source" => "keep", "current_comment_id" => 999)
        @child.update!(data: data)
        # The worker/controller may have loaded the creative before keep started.
        Task.where(id: @task.id).update_all(status: "running")
        @task.reload
        @task.creative.data = {}
        @task.creative.clear_changes_information
        TriggerLoopCheckJob.stub(:perform_later, ->(*) { flunk "stopped turn was evaluated" }) do
          @task.update!(status: status)
        end
        assert_equal "awaiting_user", @child.reload.data.dig("trigger", "loop", "state")
        assert_equal 999, @child.data.dig("trigger", "loop", "current_comment_id")
      end
    end

    test "stopping unrelated or inactive turns preserves loop configuration" do
      [ { "source" => "drop" }, { "state" => "paused" }, { "state" => "completed" },
        { "current_comment_id" => 1000 }, { "trigger_topic_id" => nil } ].each do |change|
        config = TriggerLoopConfig.build(@topic.id, source: "keep", current_comment_id: 999).merge(change)
        @child.update!(data: { "trigger" => { "loop" => config } })
        Task.where(id: @task.id).update_all(status: "running")
        @task.reload.update!(status: "cancelled")
        assert_equal config, @child.reload.data.dig("trigger", "loop")
      end
    end

    test "stopping a covering keep task recognizes coalesced and dropped dispatches" do
      [ Orchestration::TaskCoalescer::PAYLOAD_KEY, Orchestration::DeliveryRecord::DROPPED_KEY ].each do |key|
        config = TriggerLoopConfig.build(@topic.id, source: "keep", current_comment_id: 999)
        @child.update!(data: { "trigger" => { "loop" => config } })
        Task.where(id: @task.id).update_all(status: "running", trigger_event_payload: { "comment" => { "id" => 1 }, key => [ 999 ] })
        @task.reload.update!(status: "cancelled")
        assert_equal "awaiting_user", @child.reload.data.dig("trigger", "loop", "state")
      end
    end

    test "terminal tasks without creatives and non-comment tasks do not change keep" do
      config = TriggerLoopConfig.build(@topic.id, source: "keep", current_comment_id: 999)
      @child.update!(data: { "trigger" => { "loop" => config } })
      Task.where(id: @task.id).update_all(status: "running", creative_id: nil)
      @task.reload.update!(status: "failed")
      Task.where(id: @task.id).update_all(status: "running", creative_id: @child.id, trigger_event_name: "manual")
      @task.reload.update!(status: "cancelled")
      assert_equal config, @child.reload.data.dig("trigger", "loop")
    end

    test "continuation recovery does not overwrite pause or a replacement loop" do
      [ { "state" => "paused" }, { "start_comment_id" => 1000, "current_comment_id" => 1000 } ].each do |change|
        config = TriggerLoopConfig.build(@topic.id, source: "keep", current_comment_id: 999, start_comment_id: 999)
        @child.update!(data: { "trigger" => { "loop" => config } })
        @child.comments.create!(content: "[STATUS: CONTINUE]", user: @ai_bot, task: @task, topic: @topic, skip_dispatch: true)
        job = TriggerLoopCheckJob.new
        restore = job.method(:restore_retryable_loop_turn)
        expected = nil
        job.stub(:restore_retryable_loop_turn, ->(creative) {
          creative.reload
          data = creative.data.deep_dup
          data["trigger"]["loop"].merge!(change)
          creative.update!(data: data)
          expected = data["trigger"]["loop"].deep_dup
          restore.call(creative)
        }) do
          SystemEvents::Dispatcher.stub(:dispatch, ->(*) { raise "dispatch unavailable" }) do
            assert_raises(RuntimeError) { job.perform(@task.id) }
          end
        end
        assert_equal expected, @child.reload.data.dig("trigger", "loop")
      end
    end

    test "coalescing the current keep task leaves the surviving turn running" do
      config = TriggerLoopConfig.build(@topic.id, source: "keep", current_comment_id: 999)
      @child.update!(data: { "trigger" => { "loop" => config } })
      Task.where(id: @task.id).update_all(status: "queued")
      survivor = Task.create!(name: "Surviving turn", status: "queued", agent: @ai_bot, creative: @child,
        topic_id: @topic.id, trigger_event_name: "comment_created", trigger_event_payload: { "comment" => { "id" => 1000 } })
      assert_includes Orchestration::TaskCoalescer.coalesce!(survivor), @task.id
      assert_equal "cancelled", @task.reload.status
      assert_equal config, @child.reload.data.dig("trigger", "loop")
      assert @child.trigger_loop_task?(survivor.reload)
      survivor.update!(status: "cancelled")
      assert_equal "awaiting_user", @child.reload.data.dig("trigger", "loop", "state")
    end

    test "another active or completed keep turn retains loop ownership after a sibling stops" do
      %w[running done].each do |status|
        config = TriggerLoopConfig.build(@topic.id, source: "keep", current_comment_id: 999)
        @child.update!(data: { "trigger" => { "loop" => config } })
        Task.where(id: @task.id).update_all(status: "running")
        survivor = Task.create!(name: "Ambient sibling", status: status, agent: @ai_bot, creative: @child,
          topic_id: @topic.id, trigger_event_name: "comment_created", trigger_event_payload: { "comment" => { "id" => 999 } })
        @child.comments.create!(content: "[STATUS: CONTINUE]", user: @ai_bot, task: survivor, topic: @topic, skip_dispatch: true) if status == "done"
        @task.reload.update!(status: "cancelled")
        assert_equal config, @child.reload.data.dig("trigger", "loop")
        survivor.destroy!
      end
    end

    test "successful keep tasks still schedule evaluation with the configured cooldown" do
      config = TriggerLoopConfig.build(@topic.id, source: "keep", current_comment_id: 999, cooldown_seconds: 15)
      @child.update!(data: { "trigger" => { "loop" => config } })
      Task.where(id: @task.id).update_all(status: "running")
      @child.comments.create!(content: "[STATUS: CONTINUE]", user: @ai_bot, task: @task, topic: @topic, skip_dispatch: true)
      configured = Minitest::Mock.new
      configured.expect(:perform_later, true, [ @task.id ])
      TriggerLoopCheckJob.stub(:set, ->(wait:) { assert_equal 15.seconds, wait; configured }) do
        @task.reload.update!(status: "done")
      end
      configured.verify
      assert_equal "running", @child.reload.data.dig("trigger", "loop", "state")
    end

    test "status evaluation uses the accepted task reply despite newer same-agent responses" do
      reply = @child.comments.create!(content: "[STATUS: CONTINUE]", user: @ai_bot, topic: @topic,
                                      task: @task, skip_dispatch: true)
      [ "[STATUS: DONE]", "[STATUS: BLOCKED]", "Connection timed out" ].each do |content|
        @child.comments.create!(content: content, user: @ai_bot, topic: @topic, skip_dispatch: true)
        assert_equal reply, TriggerLoopCheckJob.new.send(:find_last_agent_comment, @child, @topic, @task)
      end
      data = @child.data.deep_dup
      data["trigger"]["loop"].merge!("source" => "keep", "current_comment_id" => 999)
      @child.update!(data: data)
      SystemEvents::Dispatcher.stub(:dispatch, [ @ai_bot ]) { TriggerLoopCheckJob.perform_now(@task.id) }
      assert_equal "running", @child.reload.data.dig("trigger", "loop", "state")
      assert_equal 1, @child.data.dig("trigger", "loop", "current_iteration")
    end

    test "status evaluation does not substitute an unrelated response when the task reply is missing" do
      @child.comments.create!(content: "[STATUS: DONE]", user: @ai_bot, topic: @topic, skip_dispatch: true)
      assert_nil TriggerLoopCheckJob.new.send(:find_last_agent_comment, @child, @topic, @task)
    end

    test "pause after transition prevents continuation and infrastructure retry dispatch" do
      [ "[STATUS: CONTINUE]", "Connection timed out" ].each do |response|
        [ false, true ].each do |resume|
          @child.update!(data: { "trigger" => { "loop" => TriggerLoopConfig.build(@topic.id) } })
          @child.comments.create!(content: response, user: @ai_bot, task: @task, topic: @topic, skip_dispatch: true)
          job = TriggerLoopCheckJob.new
          original = job.method(:continuation_agent)
          resuming = false
          job.stub(:continuation_agent, ->(creative, topic) {
            Creatives::TriggerActionCommand.new(creative: creative, user: @human, action: "pause").call
            if resume
              resuming = true
              Creatives::TriggerActionCommand.new(creative: creative, user: @human, action: "resume").call
              resuming = false
            end
            original.call(creative, topic)
          }) do
            SystemEvents::Dispatcher.stub(:dispatch, ->(*) { assert resuming, "stale evaluator dispatched"; [ @ai_bot ] }) do
              job.perform(@task.id)
            end
          end
          assert_equal(resume ? "running" : "paused", @child.reload.data.dig("trigger", "loop", "state"))
        end
      end
    end

    %w[running done].product([ false, true ]).each do |status, current_turn|
      test "abandoned keep replay only yields to #{status} current_turn=#{current_turn}" do
        @topic.update!(name: "Ordinary discussion")
        @child.update!(data: @child.data.deep_merge("trigger" => { "loop" => {
          "source" => "keep", "start_comment_id" => 999, "current_comment_id" => 999
        } }))
        @task.reload.update!(trigger_event_payload: {
          "comment" => { "id" => 999 }, "engine_login" => { "replay_abandoned" => true }
        })
        newer = @task.dup
        newer.assign_attributes(status: "running", created_at: @task.created_at + 1.second,
          trigger_event_payload: { "comment" => { "id" => current_turn ? 999 : 1000 } })
        newer.save!
        if status == "done"
          newer.update_columns(status: "done")
          @child.comments.create!(content: "[STATUS: CONTINUE]", user: @ai_bot, topic: @topic,
            task: newer, skip_dispatch: true)
        end
        before = @child.comments.count
        TriggerLoopCheckJob.perform_now(@task.id)
        assert_equal(current_turn ? "running" : "awaiting_user", @child.reload.data.dig("trigger", "loop", "state"))
        assert_equal 0, @child.data.dig("trigger", "loop", "current_iteration")
        assert_equal 999, @child.data.dig("trigger", "loop", "current_comment_id")
        assert_equal before + (current_turn ? 0 : 1), @child.comments.count
      end
    end

    test "keep ignores unrelated tasks and consumes each current turn once" do
      data = @child.data.deep_dup
      data["trigger"]["loop"].merge!("source" => "keep", "start_comment_id" => 900, "current_comment_id" => 999)
      @child.update!(data: data)
      @child.comments.create!(content: "[STATUS: CONTINUE]", user: @ai_bot, task: @task, topic: @topic, skip_dispatch: true)
      unrelated = Task.create!(name: "Unrelated", status: "running", created_at: @task.created_at, agent: @ai_bot, creative: @child, topic_id: @topic.id,
                               trigger_event_name: "comment_created", trigger_event_payload: { "comment" => { "id" => 1000 } })
      TriggerLoopCheckJob.perform_now(unrelated.id)
      assert_equal 0, @child.reload.data.dig("trigger", "loop", "current_iteration")
      SystemEvents::Dispatcher.stub(:dispatch, [ @ai_bot ]) do
        TriggerLoopCheckJob.perform_now(@task.id)
        next_id = @child.reload.data.dig("trigger", "loop", "current_comment_id")
        assert next_id.present?
        assert_not_equal 999, next_id
        TriggerLoopCheckJob.perform_now(@task.id)
      end
      assert_equal 1, @child.reload.data.dig("trigger", "loop", "current_iteration")
    end

    test "keep follows its current comment when deferred tasks are reanchored" do
      data = @child.data.deep_dup
      data["trigger"]["loop"].merge!("source" => "keep", "current_comment_id" => 999)
      @child.update!(data: data)
      @task.update!(trigger_event_payload: { "comment" => { "id" => 1000 }, "merged_comment_ids" => [ 999 ] })
      @child.comments.create!(content: "[STATUS: CONTINUE]", user: @ai_bot, task: @task, topic: @topic, skip_dispatch: true)
      SystemEvents::Dispatcher.stub(:dispatch, [ @ai_bot ]) { TriggerLoopCheckJob.perform_now(@task.id) }
      assert_equal 1, @child.reload.data.dig("trigger", "loop", "current_iteration")
    end

    test "keep advances a covering task only when its dispatch was dropped" do
      data = @child.data.deep_dup
      data["trigger"]["loop"].merge!("source" => "keep", "current_comment_id" => 999)
      @child.update!(data: data)
      @child.comments.create!(content: "[STATUS: CONTINUE]", user: @ai_bot, task: @task, topic: @topic, skip_dispatch: true)
      @task.reload
      payload = { "comment" => { "id" => 998 }, Orchestration::DeliveryRecord::KEY => [ 999 ] }
      @task.update!(trigger_event_payload: payload)
      assert_not @child.trigger_loop_task?(@task), "history alone must not claim the loop turn"
      assert_not @task.send(:trigger_loop_completion_eligible?)

      @task.update!(trigger_event_payload: payload.merge(Orchestration::DeliveryRecord::DROPPED_KEY => [ "999" ]))
      assert @task.reload.send(:trigger_loop_completion_eligible?)
      SystemEvents::Dispatcher.stub(:dispatch, [ @ai_bot ]) do
        TriggerLoopCheckJob.perform_now(@task.id)
        TriggerLoopCheckJob.perform_now(@task.id)
      end
      assert_equal 1, @child.reload.data.dig("trigger", "loop", "current_iteration")
    end

    test "new continuation invalidates an evaluator before any state change" do
      data = @child.data.deep_dup
      data["trigger"]["loop"].merge!("source" => "keep", "current_comment_id" => 999)
      @child.update!(data: data)
      job = TriggerLoopCheckJob.new
      job.send(:trigger_completion_topic, @task, data.dig("trigger", "loop"))
      @child.comments.create!(content: "Continue", user: @human, topic: @topic,
                              loop_continuation: true, skip_dispatch: true)
      assert_raises(TriggerLoopHelpers::StaleLoopError) do
        job.send(:update_loop_data, @child, state: "completed")
      end
      assert_equal "running", @child.reload.data.dig("trigger", "loop", "state")
    end

    test "competing completions for the same keep comment advance only once" do
      data = @child.data.deep_dup
      data["trigger"]["loop"].merge!("source" => "keep", "current_comment_id" => 999)
      @child.update!(data: data)
      @child.comments.create!(content: "[STATUS: CONTINUE]", user: @ai_bot, task: @task, topic: @topic, skip_dispatch: true)
      job = TriggerLoopCheckJob.new
      SystemEvents::Dispatcher.stub(:dispatch, [ @ai_bot ]) do
        job.stub(:evaluate_response, ->(*) { TriggerLoopCheckJob.perform_now(@task.id); :continue }) do
          job.perform(@task.id)
        end
      end
      assert_equal 1, @child.reload.data.dig("trigger", "loop", "current_iteration")
    end

    test "keep retains its authorized selected agent on continuation" do
      CreativeShare.create!(creative: @child, user: @ai_bot, permission: :feedback)
      @child.update!(data: { "trigger" => { "loop" => TriggerLoopConfig.build(
        @topic.id, source: "keep", agent_id: @ai_bot.id
      ) } })
      @child.comments.create!(content: "[STATUS: CONTINUE]", user: @ai_bot, task: @task, topic: @topic, skip_dispatch: true)
      SystemEvents::Dispatcher.stub(:dispatch, [ @ai_bot ]) { TriggerLoopCheckJob.perform_now(@task.id) }
      assert_equal "running", @child.reload.data.dig("trigger", "loop", "state")
      assert_match(/\A@#{Regexp.escape(@ai_bot.name)}:/, @child.comments.order(:id).last.content)
    end

    test "fallback evaluation cannot undo pause or pause then resume" do
      [ false, true ].each do |resume|
        @child.update!(data: { "trigger" => { "loop" => TriggerLoopConfig.build(@topic.id) } })
        @child.comments.create!(content: "Still working", user: @ai_bot, task: @task, topic: @topic, skip_dispatch: true)
        job = TriggerLoopCheckJob.new
        job.stub(:llm_fallback_evaluate, ->(*) {
          Creatives::TriggerActionCommand.new(creative: @child.reload, user: @human, action: "pause").call
          if resume
            Creatives::TriggerActionCommand.new(creative: @child.reload, user: @human, action: "resume").call
          end
          :continue
        }) { job.perform(@task.id) }
        assert_equal(resume ? "running" : "paused", @child.reload.data.dig("trigger", "loop", "state"))
        assert_equal 0, @child.data.dig("trigger", "loop", "current_iteration")
      end
    end

    test "keep continuation and infrastructure retry await user when selected agent is unavailable" do
      [ "[STATUS: CONTINUE]", "Connection timed out" ].each do |content|
        [ @ai_bot.id, -1 ].each do |agent_id|
          @child.update!(data: { "trigger" => { "loop" => TriggerLoopConfig.build(
            @topic.id, source: "keep", agent_id: agent_id
          ) } })
          CreativeShare.where(creative: @parent, user: @ai_bot).update_all(permission: :read)
          @child.comments.create!(content: content, user: @ai_bot, task: @task, topic: @topic, skip_dispatch: true)
          TriggerLoopCheckJob.perform_now(@task.id)
          assert_equal "awaiting_user", @child.reload.data.dig("trigger", "loop", "state")
          notice = @child.comments.order(:id).last
          assert_nil notice.user_id
          assert_equal I18n.t("collavre.comments.keep_command.agent_not_authorized"), notice.content
        end
      end
    end

    test "check abandons a superseded loop during evaluation" do
      @child.comments.create!(content: "[STATUS: CONTINUE]", user: @ai_bot, task: @task, topic: @topic, skip_dispatch: true)
      job = TriggerLoopCheckJob.new
      job.stub(:evaluate_response, ->(*) {
        data = @child.reload.data.deep_dup
        data["trigger"]["loop"].merge!("source" => "keep", "start_comment_id" => 1000)
        @child.update!(data: data)
        :continue
      }) { job.perform(@task.id) }
      assert_equal 0, @child.reload.data.dig("trigger", "loop", "current_iteration")
    end

    test "an in flight drop evaluator cannot overwrite a new keep generation" do
      job = TriggerLoopCheckJob.new
      job.send(:trigger_completion_topic, @task, @child.data.dig("trigger", "loop"))
      data = @child.data.deep_dup
      data["trigger"]["loop"].merge!("source" => "keep", "start_comment_id" => 1000)
      @child.update!(data: data)
      assert_raises(TriggerLoopHelpers::StaleLoopError) do
        job.send(:update_loop_data, @child, state: "completed")
      end
      assert_equal "running", @child.reload.data.dig("trigger", "loop", "state")
    end

    test "keep continues without a trigger parent or explicit agent" do
      Creative.where(id: @child.id).update_all(parent_id: nil)
      @child.reload
      data = @child.data.deep_dup
      data["trigger"]["loop"].merge!("source" => "keep", "goal" => "Deliver the feature")
      @child.update!(data: data)
      @child.comments.create!(content: "[STATUS: CONTINUE]", user: @ai_bot, task: @task, topic: @topic, skip_dispatch: true)

      SystemEvents::Dispatcher.stub(:dispatch, [ @ai_bot ]) { TriggerLoopCheckJob.perform_now(@task.id) }

      assert_equal 1, @child.reload.data.dig("trigger", "loop", "current_iteration")
      continuation = @child.comments.order(:id).last
      assert_includes continuation.content, I18n.t("collavre.trigger_loop.continue", iteration: 1, max: 3)
      refute_match(/@/, continuation.content)
      assert_includes TriggerLoopCheckJob.new.send(:collect_fallback_instructions, @child, @child, @ai_bot), "Deliver the feature"
    end

    test "keep completion uses the shared verification job" do
      data = @child.data.deep_dup
      data["trigger"]["loop"]["source"] = "keep"
      @child.update!(data: data)
      @parent.update!(data: {})
      @child.comments.create!(content: "[STATUS: DONE]", user: @ai_bot, task: @task, topic: @topic, skip_dispatch: true)

      TriggerLoopVerifyJob.stub(:perform_later, ->(id) { assert_equal @task.id, id }) do
        TriggerLoopCheckJob.perform_now(@task.id)
      end
      assert_equal "pending_verification", @child.reload.data.dig("trigger", "loop", "state")
    end

    test "evaluator usage inherits causal requesters and uses evaluator ownership" do
      verifier = users(:two)
      verifier.update!(llm_vendor: "google", llm_model: "test", created_by_id: users(:three).id)
      CreativeShare.create!(creative: @parent, user: verifier, permission: :feedback)
      @task.update!(usage_attribution: { "requester_ids" => [ @human.id ], "owner_id" => @human.id })
      @child.comments.create!(content: "Finished the work", topic: @topic, user: @ai_bot, task: @task,
        skip_dispatch: true, created_at: @task.created_at + 1.second)
      factory = ->(**options) {
        LlmUsage::Recorder.new(context: options.fetch(:context), vendor: options[:vendor], model: options[:model]).finish
        client = Object.new
        client.define_singleton_method(:judge) { |*, **| { "answers" => { "status" => { "choice" => "DONE" } } } }
        client
      }
      job = TriggerLoopCheckJob.new
      job.stub(:pick_fallback_agent, verifier) do
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

    test "stale loop completion update preserves committed type and unrelated loop fields" do
      stale = Creative.find(@child.id)
      latest = @child.data.deep_merge("kind" => "project", "trigger" => { "loop" => { "max_iterations" => 42 } })
      Creative.where(id: @child.id).update_all(data: latest)

      TriggerLoopCheckJob.new.send(:update_loop_data, stale, state: "completed", last_task_id: 123)

      expected = latest.deep_merge("trigger" => { "loop" => { "state" => "completed", "last_task_id" => 123 } })
      assert_equal expected, @child.reload.data
    end

    [ "failed", "cancelled", "escalated" ].product([ false, true ]).each do |status, external|
      test "abandonment is rechecked when newer turn becomes #{status} via #{external ? 'external claim' : 'callback'}" do
        @task.reload.update!(trigger_event_payload: { "engine_login" => { "replay_abandoned" => true } })
        newer = @task.dup
        newer.assign_attributes(status: "running", trigger_event_payload: {}, created_at: @task.created_at + 1.second)
        newer.save!
        TriggerLoopCheckJob.perform_now(@task.id)
        assert_equal "running", @child.reload.data.dig("trigger", "loop", "state")
        checks = []
        TriggerLoopCheckJob.stub(:perform_later, ->(id) { checks << id }) do
          if external
            newer.update_columns(status: status)
            newer.fire_completion_callbacks_after_external_claim
          else
            newer.update!(status: status)
          end
        end
        assert_equal [ @task.id ], checks
        SystemEvents::Dispatcher.stub(:dispatch, ->(*) { [] }) do
          checks.each { |id| TriggerLoopCheckJob.perform_now(id) }
        end
        assert_equal "awaiting_user", @child.reload.data.dig("trigger", "loop", "state")
        assert_equal 0, @child.data.dig("trigger", "loop", "current_iteration")
      end
    end

    [ false, true ].product([ false, true ]).each do |external, finish_first|
      test "blank ordinary turn releases abandonment via #{external ? 'external claim' : 'callback'} with finish_first=#{finish_first}" do
        @task.reload.update!(trigger_event_payload: { "engine_login" => { "replay_abandoned" => true } })
        newer = @task.dup
        newer.assign_attributes(status: "running", created_at: @task.created_at + 1.second,
          trigger_event_payload: { Orchestration::DeliveryRecord::HANDED_OFF_KEY => true })
        newer.save!
        placeholder = @child.comments.create!(content: "Thinking...", user: @ai_bot, topic: @topic,
          task: newer, skip_dispatch: true)
        unless finish_first
          TriggerLoopCheckJob.perform_now(@task.id)
          assert_equal "running", @child.reload.data.dig("trigger", "loop", "state")
        end
        assert_nil AiAgent::ResponseFinalizer.new(task: newer, agent: @ai_bot, original_comment: nil,
          reply_comment: placeholder, response_content: " \n").finalize
        assert_not Comment.exists?(placeholder.id)
        assert_empty CliProxy::ReplayClaims.ids(newer.trigger_event_payload)
        checks = []
        TriggerLoopCheckJob.stub(:perform_later, ->(id) { checks << id }) do
          if external
            newer.update_columns(status: "done")
            newer.fire_completion_callbacks_after_external_claim
          else
            newer.done!
          end
        end
        assert_equal [ @task.id ], checks
        before = @child.comments.count
        SystemEvents::Dispatcher.stub(:dispatch, ->(*) { [] }) do
          TriggerLoopCheckJob.perform_now(@task.id) if finish_first
          checks.each { |id| TriggerLoopCheckJob.perform_now(id) }
        end
        assert_equal "awaiting_user", @child.reload.data.dig("trigger", "loop", "state")
        assert_equal 0, @child.data.dig("trigger", "loop", "current_iteration")
        assert_equal before + 1, @child.comments.count
        assert_equal I18n.t("collavre.inline_agent_login.replay_abandoned"), @child.comments.last.content
      end
    end

    %w[cancelled failed escalated].each do |ending|
      test "external #{ending} replay settles its original login exactly once" do
        @task.reload.update!(trigger_event_payload: { "engine_login" => { "retryable" => true, "resumed" => true } })
        replay = @task.dup
        replay.assign_attributes(status: "running", trigger_event_payload: { "inline_login_task_id" => @task.id })
        replay.save!
        replay.update_columns(status: ending)
        checks = []
        TriggerLoopCheckJob.stub(:perform_later, ->(id) { checks << id }) do
          2.times { replay.fire_completion_callbacks_after_external_claim }
        end
        assert_equal [ @task.id ], checks
        assert_equal true, @task.reload.trigger_event_payload.dig("engine_login", "replay_abandoned")
        SystemEvents::Dispatcher.stub(:dispatch, ->(*) { [] }) { TriggerLoopCheckJob.perform_now(checks.first) }
        assert_equal "awaiting_user", @child.reload.data.dig("trigger", "loop", "state")
      end
    end

    [ false, true ].each do |external|
      test "successful survivor settles all login claims via #{external ? 'external claim' : 'callback'} without duplicate loop checks" do
        @task.reload.update!(trigger_event_payload: { "engine_login" => { "retryable" => true, "resumed" => true } })
        second = @task.dup
        second.save!
        replay = @task.dup
        replay.assign_attributes(status: "running", trigger_event_payload: {
          "inline_login_task_id" => @task.id, "inline_login_task_ids" => [ @task.id, second.id ]
        })
        replay.save!
        @child.comments.create!(content: "More work [STATUS: CONTINUE]", topic: @topic, user: @ai_bot,
                                task: replay, created_at: replay.created_at + 1.second, skip_dispatch: true)
        checks = []
        TriggerLoopCheckJob.stub(:perform_later, ->(id) { checks << id }) do
          if external
            replay.update_columns(status: "done")
            replay.fire_completion_callbacks_after_external_claim
          else
            replay.done!
          end
          [ @task, second ].each do |original|
            original.reload.fire_completion_callbacks_after_external_claim
            assert_no_changes -> { original.reload.updated_at } do
              CliProxy::ReplayClaims.complete!(original)
              CliProxy::InlineLogin.abandon_replay!(original, pending: true)
            end
          end
        end
        assert_equal [ replay.id ], checks
        [ @task, second ].each do |original|
          data = original.reload.trigger_event_payload.fetch("engine_login")
          assert_equal true, data["replay_completed"]
          assert_equal true, data["resumed"]
          assert_equal false, data["retryable"]
          assert_not data["replay_abandoned"]
        end
        SystemEvents::Dispatcher.stub(:dispatch, ->(*) { [] }) { TriggerLoopCheckJob.perform_now(replay.id) }
        assert_equal "running", @child.reload.data.dig("trigger", "loop", "state")
        assert_equal 1, @child.data.dig("trigger", "loop", "current_iteration")
      end
    end

    [ false, true ].each do |external|
      test "empty survivor abandons all login claims via #{external ? 'external claim' : 'callback'} and releases the loop" do
        @task.reload.update!(trigger_event_payload: { "engine_login" => { "retryable" => true, "resumed" => true } })
        second = @task.dup
        second.save!
        replay = @task.dup
        replay.assign_attributes(status: "running", trigger_event_payload: {
          "inline_login_task_ids" => [ @task.id, second.id ], Orchestration::DeliveryRecord::HANDED_OFF_KEY => true
        })
        replay.save!
        checks = []
        TriggerLoopCheckJob.stub(:perform_later, ->(id) { checks << id }) do
          external ? replay.update_columns(status: "done") : replay.done!
          replay.fire_completion_callbacks_after_external_claim
        end
        assert_equal [ @task.id, second.id ], checks
        [ @task, second ].each do |original|
          data = original.reload.trigger_event_payload.fetch("engine_login")
          assert_equal true, data["replay_abandoned"]
          assert_equal false, data["retryable"]
          assert_not data["replay_completed"]
        end
        notices = @child.comments.count
        SystemEvents::Dispatcher.stub(:dispatch, ->(*) { [] }) do
          checks.each { |id| TriggerLoopCheckJob.perform_now(id) }
        end
        assert_equal "awaiting_user", @child.reload.data.dig("trigger", "loop", "state")
        assert_equal notices + 1, @child.comments.count
      end
    end

    [ false, true ].product([ false, true ]).each do |external, error_reply|
      test "failed handoff settles all claims via #{external ? 'external claim' : 'callback'} with error_reply=#{error_reply}" do
        @task.reload.update!(trigger_event_payload: { "engine_login" => { "retryable" => true, "resumed" => true } })
        second = @task.dup
        second.save!
        replay = @task.dup
        replay.assign_attributes(status: "running", trigger_event_payload: {
          "inline_login_task_ids" => [ @task.id, second.id ], Orchestration::DeliveryRecord::HANDOFF_FAILED_KEY => true
        })
        replay.save!
        if error_reply
          @child.comments.create!(content: "⚠️ AI Error: connection failed", user: @ai_bot, topic: @topic,
            task: replay, skip_dispatch: true)
          replay.task_actions.create!(action_type: "reply_created", status: "done")
        end
        checks = []
        TriggerLoopCheckJob.stub(:perform_later, ->(id) { checks << id }) do
          external ? replay.update_columns(status: "done") : replay.done!
          replay.fire_completion_callbacks_after_external_claim
        end
        assert_equal [ @task.id, second.id ], checks
        [ @task, second ].each do |original|
          data = original.reload.trigger_event_payload.fetch("engine_login")
          assert_equal true, data["replay_abandoned"]
          assert_equal false, data["retryable"]
          assert_equal false, data["resumed"]
          assert_not data["replay_completed"]
        end
        SystemEvents::Dispatcher.stub(:dispatch, ->(*) { [] }) do
          assert_difference -> { @child.comments.count }, 1 do
            checks.each { |id| TriggerLoopCheckJob.perform_now(id) }
          end
        end
        assert_equal "awaiting_user", @child.reload.data.dig("trigger", "loop", "state")
        assert_equal 0, @child.data.dig("trigger", "loop", "current_iteration")
      end
    end

    test "a finalized review without a reply placeholder completes its login claim" do
      @task.reload.update!(trigger_event_payload: { "engine_login" => { "retryable" => true, "resumed" => true } })
      replay = @task.dup
      replay.assign_attributes(status: "running", trigger_event_payload: { "inline_login_task_id" => @task.id })
      replay.save!
      quoted = @child.comments.create!(content: "Draft", user: @ai_bot, task: @task, topic: @topic, skip_dispatch: true)
      source = @child.comments.create!(content: "Review", user: @human, topic: @topic, quoted_comment: quoted, skip_dispatch: true)
      placeholder = @child.comments.create!(content: "Thinking...", user: @ai_bot, topic: @topic, task: replay, skip_dispatch: true)
      source.stub(:review_message?, true) do
        result = AiAgent::ResponseFinalizer.new(task: replay, agent: @ai_bot, original_comment: source,
          reply_comment: placeholder, response_content: "Reviewed response").finalize
        assert_equal quoted, result
      end
      assert_not Comment.exists?(placeholder.id)
      replay.reload.done!
      assert_equal true, @task.reload.trigger_event_payload.dig("engine_login", "replay_completed")
      assert_equal false, @task.trigger_event_payload.dig("engine_login", "retryable")
      assert_not replay.unsuccessful_loop_response?
    end

    [ :login, :approval, :unclaimed ].each do |ending|
      test "#{ending} replay does not settle a claim as successfully completed" do
        @task.reload.update!(trigger_event_payload: { "engine_login" => { "retryable" => true, "resumed" => ending != :unclaimed } })
        replay = @task.dup
        replay.assign_attributes(status: "running", trigger_event_payload: { "inline_login_task_id" => @task.id })
        replay.save!
        payload = replay.trigger_event_payload
        payload["engine_login"] = { "retryable" => true } if ending == :login
        replay.update!(status: ending == :approval ? "pending_approval" : "done", trigger_event_payload: payload)
        data = @task.reload.trigger_event_payload.fetch("engine_login")
        assert_equal true, data["retryable"]
        assert_not data["replay_completed"]
        assert_not data["replay_abandoned"]
      end
    end

    test "a failed survivor settles multiple inherited login claims and ends the loop once" do
      @task.reload.update!(trigger_event_payload: { "engine_login" => { "retryable" => true, "resumed" => true } })
      second = @task.dup
      second.save!
      replay = @task.dup
      replay.assign_attributes(status: "running", trigger_event_payload: {
        "inline_login_task_id" => @task.id, "inline_login_task_ids" => [ @task.id, second.id ]
      })
      replay.save!
      checks = []
      TriggerLoopCheckJob.stub(:perform_later, ->(id) { checks << id }) do
        replay.failed!
        replay.fire_completion_callbacks_after_external_claim
      end
      assert_equal [ @task.id, second.id ].sort, checks.sort
      [ @task, second ].each do |original|
        assert_equal true, original.reload.trigger_event_payload.dig("engine_login", "replay_abandoned")
      end
      SystemEvents::Dispatcher.stub(:dispatch, ->(*) { [] }) do
        assert_difference "@child.comments.count", 1 do
          checks.each { |id| TriggerLoopCheckJob.perform_now(id) }
        end
      end
      assert_equal "awaiting_user", @child.reload.data.dig("trigger", "loop", "state")
    end

    [ :missing, :agent, :creative, :topic, :self ].each do |mismatch|
      test "replay settlement ignores an invalid original linkage: #{mismatch}" do
        @task.reload.update!(trigger_event_payload: { "engine_login" => { "retryable" => true, "resumed" => true } })
        replay = @task.dup
        replay.assign_attributes(status: "running", trigger_event_payload: { "inline_login_task_id" => @task.id })
        replay.save!
        case mismatch
        when :missing then replay.update_columns(trigger_event_payload: { "inline_login_task_id" => -1 })
        when :self then replay.update_columns(trigger_event_payload: { "inline_login_task_id" => replay.id })
        when :agent then replay.update_columns(agent_id: @human.id)
        when :creative then replay.update_columns(creative_id: @parent.id)
        when :topic then replay.update_columns(topic_id: nil)
        end
        replay.cancelled!
        assert_equal true, @task.reload.trigger_event_payload.dig("engine_login", "retryable")
        assert_equal true, @task.trigger_event_payload.dig("engine_login", "resumed")
        assert_equal "running", @child.reload.data.dig("trigger", "loop", "state")
      end
    end

    test "abandonment waits for all newer active turns to end without a result" do
      @task.reload.update!(trigger_event_payload: { "engine_login" => { "replay_abandoned" => true } })
      turns = 2.times.map do |offset|
        newer = @task.dup
        newer.assign_attributes(status: "running", trigger_event_payload: {}, created_at: @task.created_at + offset.seconds)
        newer.tap(&:save!)
      end
      checks = []
      TriggerLoopCheckJob.stub(:perform_later, ->(id) { checks << id }) do
        turns.first.cancelled!
      end
      assert_equal [ @task.id ], checks
      TriggerLoopCheckJob.perform_now(checks.first)
      assert_equal "running", @child.reload.data.dig("trigger", "loop", "state")
      # Default inline adapter executes the second callback immediately.
      turns.last.failed!
      assert_equal "awaiting_user", @child.reload.data.dig("trigger", "loop", "state")
    end

    [ :topic, :creative, :event, :earlier, :not_abandoned, :completed ].product(%w[failed done]).each do |scope, ending|
      test "#{ending} turn without output does not recheck an unrelated abandoned replay: #{scope}" do
        @task.reload.update!(trigger_event_payload: { "engine_login" => { "replay_abandoned" => true } })
        newer = @task.dup
        newer.assign_attributes(status: "running", trigger_event_payload: {}, created_at: @task.created_at + 1.second)
        case scope
        when :topic then newer.topic_id = @child.topics.create!(name: "Other", user: @human).id
        when :creative then newer.creative = @parent
        when :event then newer.trigger_event_name = "creative_updated"
        when :earlier then newer.created_at = @task.created_at - 1.second
        when :not_abandoned then @task.update!(trigger_event_payload: {})
        when :completed
          @child.data["trigger"]["loop"]["state"] = "completed"
          @child.save!
        end
        newer.save!
        TriggerLoopCheckJob.stub(:perform_later, ->(*) { flunk "Unrelated failure cannot take ownership" }) do
          newer.update!(status: ending)
        end
        assert_equal scope == :completed ? "completed" : "running", @child.reload.data.dig("trigger", "loop", "state")
      end
    end

    [ 0.seconds, 1.second ].each do |delay|
      test "stale abandoned replay leaves the newer turn in control with #{delay} timestamp offset" do
        @task.update!(trigger_event_payload: { "engine_login" => { "replay_abandoned" => true } })
        @child.data["trigger"]["loop"]["current_iteration"] = 1
        @child.save!
        newer = @task.dup
        newer.assign_attributes(status: "running", trigger_event_payload: {}, created_at: @task.created_at + delay)
        newer.save!
        @child.comments.create!(
          content: "Login required", topic: @topic, user: @ai_bot, task: @task,
          created_at: @task.created_at + 2.seconds
        )
        before_loop = @child.reload.data.dig("trigger", "loop").deep_dup

        assert_no_difference -> { @child.comments.count } do
          AiClient.stub(:new, ->(*) { flunk "Stale login cards must not be evaluated" }) do
            TriggerLoopCheckJob.perform_now(@task.id)
          end
        end
        assert_equal before_loop, @child.reload.data.dig("trigger", "loop")

        @child.comments.create!(
          content: "Finished [STATUS: DONE]", topic: @topic, user: @ai_bot, task: newer,
          created_at: @task.created_at + 3.seconds
        )
        verification = Minitest::Mock.new
        verification.expect(:call, nil, [ newer.id ])
        TriggerLoopVerifyJob.stub(:perform_later, verification) do
          TriggerLoopCheckJob.perform_now(newer.id)
        end
        verification.verify
        assert_equal "pending_verification", @child.reload.data.dig("trigger", "loop", "state")
        assert_equal 1, @child.data.dig("trigger", "loop", "current_iteration")
      end
    end

    [ :older, :other_topic, :other_creative ].each do |scope|
      test "latest abandoned replay still stops when a #{scope} task exists" do
        @task.update!(trigger_event_payload: { "engine_login" => { "replay_abandoned" => true } })
        other = @task.dup
        other.assign_attributes(status: "running", trigger_event_payload: {}, created_at: @task.created_at + 1.second)
        case scope
        when :older then other.created_at = @task.created_at - 1.second
        when :other_topic then other.topic_id = @child.topics.create!(name: "Other", user: @human).id
        when :other_creative then other.creative = @parent
        end
        other.save!

        assert_difference -> { @child.comments.count }, 1 do
          TriggerLoopCheckJob.perform_now(@task.id)
        end
        assert_equal "awaiting_user", @child.reload.data.dig("trigger", "loop", "state")
        assert_equal 0, @child.data.dig("trigger", "loop", "current_iteration")
        assert_equal I18n.t("collavre.inline_agent_login.replay_abandoned"), @child.comments.last.content
      end
    end

    {
      empty_ordinary: { status: "done" },
      failed: { status: "failed" },
      cancelled: { status: "cancelled" },
      escalated: { status: "escalated" },
      non_comment_done: { status: "done", trigger_event_name: "creative_updated" },
      non_comment_running: { status: "running", trigger_event_name: "creative_updated" },
      abandoned_login: { status: "done", trigger_event_payload: { "engine_login" => { "retryable" => false, "replay_abandoned" => true } } }
    }.each do |reason, attributes|
      test "abandoned replay finishes when the newer task is ineligible: #{reason}" do
        @task.update!(trigger_event_payload: { "engine_login" => { "replay_abandoned" => true } })
        newer = @task.dup
        newer.assign_attributes(trigger_event_payload: {}, created_at: @task.created_at + 1.second)
        newer.assign_attributes(attributes)
        newer.save!

        assert_difference -> { @child.comments.count }, 1 do
          AiClient.stub(:new, ->(*) { flunk "Login notices must not be evaluated as results" }) do
            TriggerLoopCheckJob.perform_now(@task.id)
          end
        end
        assert_equal "awaiting_user", @child.reload.data.dig("trigger", "loop", "state")
        assert_equal 0, @child.data.dig("trigger", "loop", "current_iteration")
        assert_equal I18n.t("collavre.inline_agent_login.replay_abandoned"), @child.comments.last.content
      end
    end

    [ :response, :abandonment ].each do |outcome|
      test "newer login waiting turn owns the loop until #{outcome}" do
        @task.reload.update!(trigger_event_payload: { "engine_login" => { "replay_abandoned" => true } })
        newer = @task.dup
        newer.assign_attributes(created_at: @task.created_at + 1.second,
                                trigger_event_payload: { "engine_login" => { "retryable" => true, "resumed" => true } })
        newer.save!
        before_loop = @child.reload.data.dig("trigger", "loop").deep_dup

        assert_no_difference -> { @child.comments.count } do
          TriggerLoopCheckJob.perform_now(@task.id)
        end
        assert_equal before_loop, @child.reload.data.dig("trigger", "loop")

        replay = nil
        checks = []
        TriggerLoopCheckJob.stub(:perform_later, ->(id) { checks << id }) do
          if outcome == :abandonment
            CliProxy::InlineLogin.abandon_replay!(newer)
          else
            replay = newer.dup
            replay.assign_attributes(status: "running", trigger_event_payload: {}, created_at: newer.created_at + 1.second)
            replay.save!
            @child.comments.create!(content: "More work [STATUS: CONTINUE]", topic: @topic, user: @ai_bot,
                                    task: replay, created_at: replay.created_at + 1.second, skip_dispatch: true)
            replay.done!
          end
        end
        assert_equal [ outcome == :abandonment ? newer.id : replay.id ], checks
        SystemEvents::Dispatcher.stub(:dispatch, ->(*) { [] }) do
          checks.each { |id| TriggerLoopCheckJob.perform_now(id) }
        end
        assert_equal outcome == :abandonment ? "awaiting_user" : "running", @child.reload.data.dig("trigger", "loop", "state")
        assert_equal outcome == :abandonment ? 0 : 1, @child.data.dig("trigger", "loop", "current_iteration")
      end
    end

    (Task::ACTIVE_STATUSES + [ "done" ]).each do |status|
      test "newer #{status} comment task retains loop completion despite a later failed task" do
        @task.update!(trigger_event_payload: { "engine_login" => { "replay_abandoned" => true } })
        newer = @task.dup
        newer.assign_attributes(status: status, trigger_event_payload: {}, created_at: @task.created_at + 1.second)
        newer.save!
        if status == "done"
          @child.comments.create!(content: "More work [STATUS: CONTINUE]", topic: @topic, user: @ai_bot,
            task: newer, skip_dispatch: true)
        end
        failed = newer.dup
        failed.assign_attributes(status: "failed", created_at: @task.created_at + 2.seconds)
        failed.save!
        before_loop = @child.reload.data.dig("trigger", "loop").deep_dup

        assert_no_difference -> { @child.comments.count } do
          AiClient.stub(:new, ->(*) { flunk "Stale login cards must not be evaluated" }) do
            TriggerLoopCheckJob.perform_now(@task.id)
          end
        end
        assert_equal before_loop, @child.reload.data.dig("trigger", "loop")
      end
    end

    %w[reply_created review_updated].product([ false, true ]).each do |action_type, external|
      test "ordinary #{action_type} retains completion via #{external ? 'external claim' : 'callback'}" do
        @task.reload.update!(trigger_event_payload: { "engine_login" => { "replay_abandoned" => true } })
        newer = @task.dup
        newer.assign_attributes(status: "running", trigger_event_payload: {}, created_at: @task.created_at + 1.second)
        newer.save!
        newer.task_actions.create!(action_type: action_type, status: "done", payload: { content: "Final result" })
        checks = []
        TriggerLoopCheckJob.stub(:perform_later, ->(id) { checks << id }) do
          if external
            newer.update_columns(status: "done")
            newer.fire_completion_callbacks_after_external_claim
          else
            newer.done!
          end
        end
        assert_equal [ newer.id ], checks
        assert_no_difference -> { @child.comments.count } do
          TriggerLoopCheckJob.perform_now(@task.id)
        end
        assert_equal "running", @child.reload.data.dig("trigger", "loop", "state")
      end
    end

    test "transitions to pending_verification when agent reports STATUS: DONE" do
      @child.comments.create!(
        content: "All done! [STATUS: DONE]",
        topic_id: @topic.id,
        user: @ai_bot, task: @task,
        created_at: @task.created_at + 1.second
      )

      # Stub VerifyJob to prevent inline execution from changing state
      TriggerLoopVerifyJob.stub(:perform_later, ->(task_id) { }) do
        TriggerLoopCheckJob.perform_now(@task.id)
      end

      @child.reload
      assert_equal "pending_verification", @child.data.dig("trigger", "loop", "state")
    end

    test "transitions to awaiting_user when agent reports STATUS: BLOCKED" do
      @child.comments.create!(
        content: "Cannot proceed [STATUS: BLOCKED need credentials]",
        topic_id: @topic.id,
        user: @ai_bot, task: @task,
        created_at: @task.created_at + 1.second
      )

      SystemEvents::Dispatcher.stub(:dispatch, ->(*_args) { [] }) do
        assert_difference -> { @child.comments.count }, 1 do
          TriggerLoopCheckJob.perform_now(@task.id)
        end
      end

      @child.reload
      assert_equal "awaiting_user", @child.data.dig("trigger", "loop", "state")
      assert_includes @child.comments.last.content, "⏸️"
    end

    test "continues loop when agent reports STATUS: CONTINUE" do
      @child.comments.create!(
        content: "Working on it [STATUS: CONTINUE]",
        topic_id: @topic.id,
        user: @ai_bot, task: @task,
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
        user: @ai_bot, task: @task,
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
        user: @ai_bot, task: @task,
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
        user: @ai_bot, task: @task,
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
        user: @ai_bot, task: @task,
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
        user: @ai_bot, task: @task,
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
        user: @ai_bot, task: @task,
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
        user: @ai_bot, task: @task,
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

    test "falls back to stuck_conditions keywords as awaiting_user" do
      @child.comments.create!(
        content: "I need help with this",
        topic_id: @topic.id,
        user: @ai_bot, task: @task,
        created_at: @task.created_at + 1.second
      )

      SystemEvents::Dispatcher.stub(:dispatch, ->(*_args) { [] }) do
        TriggerLoopCheckJob.perform_now(@task.id)
      end

      @child.reload
      assert_equal "awaiting_user", @child.data.dig("trigger", "loop", "state")
    end

    test "defaults to continue when no status tag or keywords match" do
      @child.comments.create!(
        content: "I made some changes to the codebase",
        topic_id: @topic.id,
        user: @ai_bot, task: @task,
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
        user: @ai_bot, task: @task,
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
        user: @ai_bot, task: other_task,
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

    # --- LLM fallback tests ---

    test "LLM fallback adapter follows JSON contract for completed and blocked work" do
      job = TriggerLoopCheckJob.new
      comment = Struct.new(:content).new("The task has been evaluated")
      %w[DONE BLOCKED].each do |verdict|
        client = AiClient.new(vendor: "external-adapter", model: "test",
          system_prompt: TriggerLoopCheckJob::LLM_FALLBACK_SYSTEM_PROMPT)
        adapter = lambda do |messages, &block|
          prompt = JSON.parse(messages.first[:text])
          refute_match(/exactly one word/i, client.send(:system_prompt))
          refute_match(/exactly one word/i, prompt.fetch("input"))
          assert_includes prompt.fetch("instruction"), "Return only JSON"
          block.call({ answers: { status: { choice: verdict } } }.to_json)
          nil
        end
        client.stub(:chat, adapter) do
          job.stub(:decision_client, client) do
            expected = verdict == "DONE" ? :done : :awaiting_user
            assert_equal expected, job.send(:llm_fallback_evaluate, @child, @parent, comment, @task)
          end
        end
      end
    end

    test "LLM fallback schema rejection preserves JSON contract" do
      job = TriggerLoopCheckJob.new
      comment = Struct.new(:content).new("The task is complete")
      client = AiClient.new(vendor: "google", model: "test",
        system_prompt: TriggerLoopCheckJob::LLM_FALLBACK_SYSTEM_PROMPT)
      rejected = Object.new
      rejected.define_singleton_method(:with_schema) { |*| }
      rejected.define_singleton_method(:ask) { |*| raise RubyLLM::BadRequestError, "response_format unsupported" }
      fallback = Object.new
      fallback.define_singleton_method(:ask) do |prompt|
        raise "Conflicting format" if JSON.parse(prompt).fetch("input").match?(/exactly one word/i)

        Struct.new(:content, :tokens).new({ answers: { status: { choice: "DONE" } } }.to_json, nil)
      end
      [ rejected, fallback ].each do |chat|
        chat.define_singleton_method(:messages) { [] }
        chat.define_singleton_method(:tools) { [] }
        chat.define_singleton_method(:after_message) { |*| }
      end
      chats = [ rejected, fallback ]
      client.stub(:build_conversation, -> { chats.shift }) do
        job.stub(:decision_client, client) do
          assert_equal :done, job.send(:llm_fallback_evaluate, @child, @parent, comment, @task)
        end
      end
      assert_empty chats
    end

    test "LLM fallback: transitions to pending_verification when LLM says DONE" do
      # Agent response without [STATUS: ...] tag
      @child.comments.create!(
        content: "I've created PR #42 and moved the creative. Everything is complete.",
        topic_id: @topic.id,
        user: @ai_bot, task: @task,
        created_at: @task.created_at + 1.second
      )

      # Stub AiClient with a fake that yields "DONE" to the block
      fake_client = Object.new
      fake_client.define_singleton_method(:judge) do |*, **|
        { "answers" => { "status" => { "choice" => "DONE" } } }
      end

      TriggerLoopVerifyJob.stub(:perform_later, ->(task_id) { }) do
        AiClient.stub(:new, ->(*_args) { fake_client }) do
          TriggerLoopCheckJob.perform_now(@task.id)
        end
      end

      @child.reload
      assert_equal "pending_verification", @child.data.dig("trigger", "loop", "state")
    end

    test "LLM fallback: continues when LLM says CONTINUE" do
      @child.comments.create!(
        content: "I've made some progress but still need to create the PR.",
        topic_id: @topic.id,
        user: @ai_bot, task: @task,
        created_at: @task.created_at + 1.second
      )

      fake_client = Object.new
      fake_client.define_singleton_method(:judge) do |*, **|
        { "answers" => { "status" => { "choice" => "CONTINUE" } } }
      end

      AiClient.stub(:new, ->(*_args) { fake_client }) do
        TriggerLoopCheckJob.perform_now(@task.id)
      end

      @child.reload
      assert_equal "running", @child.data.dig("trigger", "loop", "state")
      assert_equal 1, @child.data.dig("trigger", "loop", "current_iteration")
    end

    test "LLM fallback: marks awaiting_user when LLM says BLOCKED" do
      @child.comments.create!(
        content: "I can't proceed because I don't have permission to access the repo.",
        topic_id: @topic.id,
        user: @ai_bot, task: @task,
        created_at: @task.created_at + 1.second
      )

      fake_client = Object.new
      fake_client.define_singleton_method(:judge) do |*, **|
        { "answers" => { "status" => { "choice" => "BLOCKED" } } }
      end

      AiClient.stub(:new, ->(*_args) { fake_client }) do
        TriggerLoopCheckJob.perform_now(@task.id)
      end

      @child.reload
      assert_equal "awaiting_user", @child.data.dig("trigger", "loop", "state")
    end

    test "LLM fallback: defaults to continue on LLM error" do
      @child.comments.create!(
        content: "Some work done without status tags.",
        topic_id: @topic.id,
        user: @ai_bot, task: @task,
        created_at: @task.created_at + 1.second
      )

      # Stub AiClient to raise an error
      AiClient.stub(:new, ->(*_args) { raise StandardError, "LLM unavailable" }) do
        TriggerLoopCheckJob.perform_now(@task.id)
      end

      @child.reload
      # Should default to continue (iteration increments)
      assert_equal "running", @child.data.dig("trigger", "loop", "state")
      assert_equal 1, @child.data.dig("trigger", "loop", "current_iteration")
    end

    test "LLM fallback: defaults to continue when no AI agent available" do
      # Remove all AI agent shares so no fallback agent can be found
      CreativeShare.where(creative: @parent, user: @ai_bot).destroy_all

      @child.comments.create!(
        content: "Work done but no status tag.",
        topic_id: @topic.id,
        user: @ai_bot, task: @task,
        created_at: @task.created_at + 1.second
      )

      # No agent → no continue comment posted, but state should still update
      # However, post_continue_instruction returns early if no agent found,
      # so the iteration still increments but no comment is posted
      TriggerLoopCheckJob.perform_now(@task.id)

      @child.reload
      assert_equal "running", @child.data.dig("trigger", "loop", "state")
      assert_equal 1, @child.data.dig("trigger", "loop", "current_iteration")
    end
  end
end
