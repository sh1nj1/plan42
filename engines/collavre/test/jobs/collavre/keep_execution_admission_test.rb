# frozen_string_literal: true

require "test_helper"

module Collavre
  class KeepExecutionAdmissionTest < ActiveSupport::TestCase
    setup do
      @creative = creatives(:tshirt)
      @agent = users(:ai_bot)
      CreativeShare.find_or_create_by!(creative: @creative, user: @agent).update!(permission: "feedback")
      CreativeSharesCache.find_or_create_by!(creative: @creative, user: @agent, permission: :feedback)
      @topic = @creative.main_topic
      @turn = @creative.comments.create!(content: "Keep turn", user: users(:one), topic: @topic, skip_dispatch: true)
      @config = TriggerLoopConfig.build(@topic.id, source: "keep", start_comment_id: @turn.id, current_comment_id: @turn.id)
      @creative.update!(data: { "trigger" => { "loop" => @config } })
      @context = @turn.reload.dispatch_payload.deep_stringify_keys
      Orchestration::ResourceTracker.for(@agent).reset!
    end

    test "execution time permission rejection releases the current keep turn" do
      Creatives::PermissionChecker.stub(:current_allowed?, false) { dispatch }
      assert_equal "awaiting_user", @creative.reload.data.dig("trigger", "loop", "state")
      assert_equal 0, Task.where(creative: @creative, topic_id: @topic.id).count
    end

    test "assignment rejection releases the current keep turn" do
      Orchestration::Matcher.stub(:prepare_waiting_payload, nil) { dispatch }
      assert_equal "awaiting_user", @creative.reload.data.dig("trigger", "loop", "state")
    end

    test "queued dispatch cannot create a task after replacement" do
      replacement = @config.merge("start_comment_id" => @turn.id + 1, "current_comment_id" => @turn.id + 1)
      @creative.update!(data: { "trigger" => { "loop" => replacement } })
      assert_no_difference "Task.count" do
        AiAgentService.stub(:new, ->(*) { flunk "Superseded job executed" }) { dispatch }
      end
      assert_equal replacement, @creative.reload.data.dig("trigger", "loop")
    end

    test "queued dispatch cannot create a task after pause" do
      @creative.update!(data: { "trigger" => { "loop" => @config.merge("state" => "paused") } })
      assert_no_difference "Task.count" do
        AiAgentService.stub(:new, ->(*) { flunk "Paused job executed" }) { dispatch }
      end
      assert_equal "paused", @creative.reload.data.dig("trigger", "loop", "state")
    end

    test "restored job rejected at execution releases its pending restoration" do
      anchor = @creative.comments.create!(content: "Covering", user: users(:one), topic: @topic, skip_dispatch: true)
      covering = Task.create!(name: "Cover", status: "running", creative: @creative, agent: @agent,
        topic_id: @topic.id, trigger_event_name: "comment_created", trigger_event_payload: anchor.dispatch_payload.deep_stringify_keys)
      assert Orchestration::DeliveryRecord.claim_drop!(covering, @turn.id)
      restored = nil
      AiAgentJob.stub(:perform_later, ->(*args) { restored = args; true }) do
        Orchestration::Matcher.stub(:permits_creative_access?, true) { covering.update!(status: "failed") }
      end
      assert restored
      Orchestration::Matcher.stub(:prepare_waiting_payload, nil) { AiAgentJob.new.perform(*restored) }
      assert_equal "awaiting_user", @creative.reload.data.dig("trigger", "loop", "state")
    end

    test "offline selected agent releases a current dispatch without a task" do
      User.stub(:find, @agent) do
        @agent.stub(:claude_channel_agent?, true) do
          @agent.stub(:claude_channel_online?, false) { dispatch }
        end
      end
      assert_equal "awaiting_user", @creative.reload.data.dig("trigger", "loop", "state")
    end

    test "rejected dispatch preserves another active owner" do
      owner = task_for("running")
      Orchestration::Matcher.stub(:prepare_waiting_payload, nil) { dispatch }
      assert_equal "running", @creative.reload.data.dig("trigger", "loop", "state")
      assert_equal "running", owner.reload.status
    end

    test "rejected dispatch preserves another pending restoration" do
      owner = task_for("running")
      assert Orchestration::DeliveryRecord.claim_drop!(owner, @turn.id)
      owner.update_columns(status: "failed")
      Orchestration::Matcher.stub(:prepare_waiting_payload, nil) { dispatch }
      assert_equal "running", @creative.reload.data.dig("trigger", "loop", "state")
    end

    test "unchanged current dispatch executes after admission locks are released" do
      service = Object.new
      @transactions_before = Task.connection.open_transactions
      service.define_singleton_method(:call) { true }
      factory = ->(*) { assert_equal @transactions_before, Task.connection.open_transactions; service }
      AiAgentService.stub(:new, factory) { assert_difference("Task.count", 1) { dispatch } }
    end

    test "resumed waiter is cancelled after its keep generation is replaced" do
      waiter = task_for("pending")
      replacement = @config.merge("start_comment_id" => @turn.id + 1, "current_comment_id" => @turn.id + 1)
      @creative.update!(data: { "trigger" => { "loop" => replacement } })
      AiAgentService.stub(:new, ->(*) { flunk "Stale waiter executed" }) { AiAgentJob.new.perform(waiter) }
      assert_equal "cancelled", waiter.reload.status
      assert_equal replacement, @creative.reload.data.dig("trigger", "loop")
    end

    test "resumed waiter losing permission releases the current turn" do
      waiter = task_for("pending")
      Creatives::PermissionChecker.stub(:current_allowed?, false) { AiAgentJob.new.perform(waiter) }
      assert_equal "cancelled", waiter.reload.status
      assert_equal "awaiting_user", @creative.reload.data.dig("trigger", "loop", "state")
    end

    test "current admitted waiter can finish normally" do
      waiter = task_for("pending")
      service = Object.new
      service.define_singleton_method(:call) { true }
      AiAgentService.stub(:new, ->(*) { service }) { AiAgentJob.new.perform(waiter) }
      assert_equal "done", waiter.reload.status
    end

    test "restored dispatch does not start after a replacement is installed" do
      owner = task_for("running")
      assert Orchestration::DeliveryRecord.claim_drop!(owner, @turn.id)
      restored = nil
      AiAgentJob.stub(:perform_later, ->(*args) { restored = args; true }) { owner.update!(status: "failed") }
      assert restored
      replacement = @config.merge("start_comment_id" => @turn.id + 1, "current_comment_id" => @turn.id + 1)
      @creative.update!(data: { "trigger" => { "loop" => replacement } })
      assert_no_difference "Task.count" do
        AiAgentService.stub(:new, ->(*) { flunk "Superseded restoration executed" }) { AiAgentJob.new.perform(*restored) }
      end
      assert_equal replacement, @creative.reload.data.dig("trigger", "loop")
    end

    test "ordinary dispatch rejection still returns its rejected acknowledgement" do
      @context["comment"].delete("keep_loop_generation")
      Orchestration::Matcher.stub(:prepare_waiting_payload, nil) { assert_equal :rejected, dispatch }
      assert_equal "running", @creative.reload.data.dig("trigger", "loop", "state")
    end

    test "revoked creative access is rechecked without trusting the enqueue snapshot" do
      CreativeShare.find_by!(creative: @creative, user: @agent).update!(permission: "no_access")
      CreativeSharesCache.where(creative: @creative, user: @agent).update_all(permission: :feedback)
      assert @creative.reload.has_permission?(@agent, :feedback)
      AiAgentService.stub(:new, ->(*) { flunk "Revoked dispatch executed" }) do
        assert_no_difference("Task.count") { assert_equal :rejected, dispatch }
      end
      assert_equal "awaiting_user", @creative.reload.data.dig("trigger", "loop", "state")
    end

    test "read-only current access rejects a waiter despite stale feedback cache" do
      waiter = task_for("pending")
      CreativeShare.find_by!(creative: @creative, user: @agent).update!(permission: "read")
      CreativeSharesCache.where(creative: @creative, user: @agent).update_all(permission: :feedback)
      assert @creative.reload.has_permission?(@agent, :feedback)
      AiAgentService.stub(:new, ->(*) { flunk "Revoked waiter executed" }) { AiAgentJob.new.perform(waiter) }
      assert_equal "cancelled", waiter.reload.status
      assert_equal "awaiting_user", @creative.reload.data.dig("trigger", "loop", "state")
    end

    test "same-anchor replay rebuilding retains stale keep identity" do
      @context["comment"]["keep_restore_task_id"] = 123
      replacement = @config.merge("start_comment_id" => @turn.id + 1, "current_comment_id" => @turn.id + 1)
      @creative.update!(data: { "trigger" => { "loop" => replacement } })
      @context = Orchestration::TaskCoalescer.reanchor_payload(@context, @turn.reload)
      assert_equal 123, @context.dig("comment", "keep_restore_task_id")
      assert_equal @config.slice("start_comment_id", "current_comment_id", "trigger_topic_id"), @context.dig("comment", "keep_loop_generation")
      assert_no_difference("Task.count") { assert_equal :rejected, dispatch }
      assert_equal replacement, @creative.reload.data.dig("trigger", "loop")
    end

    test "acquiring a different anchor does not inherit the old keep identity" do
      @context["comment"]["keep_restore_task_id"] = 123
      other = @creative.comments.create!(content: "Unrelated", user: users(:one), topic: @topic, skip_dispatch: true)
      moved = Orchestration::TaskCoalescer.reanchor_payload(@context, other)
      refute moved.dig("comment", "keep_loop_generation")
      refute moved.dig("comment", "keep_restore_task_id")
    end

    def task_for(status)
      Task.create!(name: "Keep owner", status: status, creative: @creative, agent: @agent,
        topic_id: @topic.id, trigger_event_name: "comment_created", trigger_event_payload: @context.deep_dup)
    end

    private

    def dispatch
      AiAgentJob.new.perform(@agent.id, "comment_created", @context)
    end
  end
end
