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
      quoted = @child.comments.create!(content: "Draft", user: @ai_bot, topic: @topic, skip_dispatch: true)
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
        user: @ai_bot,
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
        user: @ai_bot,
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

    test "falls back to stuck_conditions keywords as awaiting_user" do
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
      assert_equal "awaiting_user", @child.data.dig("trigger", "loop", "state")
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

    # --- LLM fallback tests ---

    test "LLM fallback: transitions to pending_verification when LLM says DONE" do
      # Agent response without [STATUS: ...] tag
      @child.comments.create!(
        content: "I've created PR #42 and moved the creative. Everything is complete.",
        topic_id: @topic.id,
        user: @ai_bot,
        created_at: @task.created_at + 1.second
      )

      # Stub AiClient with a fake that yields "DONE" to the block
      fake_client = Object.new
      fake_client.define_singleton_method(:chat) do |_messages, &block|
        block.call("DONE") if block
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
        user: @ai_bot,
        created_at: @task.created_at + 1.second
      )

      fake_client = Object.new
      fake_client.define_singleton_method(:chat) do |_messages, &block|
        block.call("CONTINUE") if block
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
        user: @ai_bot,
        created_at: @task.created_at + 1.second
      )

      fake_client = Object.new
      fake_client.define_singleton_method(:chat) do |_messages, &block|
        block.call("BLOCKED") if block
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
        user: @ai_bot,
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
        user: @ai_bot,
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
