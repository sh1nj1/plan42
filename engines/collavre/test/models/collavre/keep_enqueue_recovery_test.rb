# frozen_string_literal: true

require "test_helper"

module Collavre
  class KeepEnqueueRecoveryTest < ActiveSupport::TestCase
    setup do
      @creative = creatives(:tshirt)
      @agent = users(:ai_bot)
      @topic = @creative.main_topic
      @turn = @creative.comments.create!(content: "work", user: users(:one), topic: @topic, skip_dispatch: true)
      @creative.update!(data: { "trigger" => { "loop" => TriggerLoopConfig.build(
        @topic.id, source: "keep", start_comment_id: @turn.id, current_comment_id: @turn.id, cooldown_seconds: 0
      ) } })
      @task = Task.create!(name: "Keep turn", status: "running", creative: @creative, topic_id: @topic.id,
                          agent: @agent, trigger_event_name: "comment_created",
                          trigger_event_payload: @turn.reload.dispatch_payload.deep_stringify_keys)
      @creative.comments.create!(content: "finished [STATUS: DONE]", user: @agent, topic: @topic, task: @task, skip_dispatch: true)
    end

    test "enqueue failure revalidates durable identity despite an old creative snapshot" do
      @task.creative = Creative.find(@creative.id)
      @creative.update!(data: @creative.data.deep_merge("trigger" => { "loop" => { "control_version" => 9 } }))
      TriggerLoopCheckJob.stub(:perform_later, false) { @task.done! }
      config = @creative.reload.data.dig("trigger", "loop")
      assert_equal "awaiting_user", config["state"]
      assert_equal 10, config["control_version"]
      assert_equal 0, config["current_iteration"]
    end

    [ 0, 10 ].each do |cooldown|
      [ false, :raise ].each do |outcome|
        test "keep check enqueue #{outcome} with cooldown #{cooldown} releases committed turn" do
          @creative.update!(data: @creative.data.deep_merge("trigger" => { "loop" => { "cooldown_seconds" => cooldown } }))
          before = @creative.data.dig("trigger", "loop").deep_dup
          enqueue = ->(*) { outcome == :raise ? raise(ActiveJob::EnqueueError, "queue unavailable") : false }
          queue = cooldown.positive? ? TriggerLoopCheckJob.set(wait: cooldown.seconds) : TriggerLoopCheckJob
          TriggerLoopCheckJob.stub(:set, queue) do
            queue.stub(:perform_later, enqueue) { @task.done! }
          end
          assert @task.reload.done?
          config = @creative.reload.data.dig("trigger", "loop")
          assert_equal "awaiting_user", config["state"]
          assert_equal before["current_iteration"], config["current_iteration"]
          assert_equal @turn.id, config["current_comment_id"]
          assert_equal before.fetch("control_version", 0) + 1, config["control_version"]
        end
      end
    end

    [ 0, 10 ].each do |cooldown|
      test "acknowledged check enqueue with cooldown #{cooldown} keeps ownership" do
        @creative.update!(data: @creative.data.deep_merge("trigger" => { "loop" => { "cooldown_seconds" => cooldown } }))
        before = @creative.data.dig("trigger", "loop").deep_dup
        adapter = ActiveJob::QueueAdapters::TestAdapter.new
        TriggerLoopCheckJob.stub(:queue_adapter, adapter) do
          @task.done!
          assert_equal [ [ @task.id ] ], adapter.enqueued_jobs.map { |job| job[:args] }
          assert_equal before, @creative.reload.data.dig("trigger", "loop")
        end
      end
    end

    test "drop check enqueue exception still propagates without changing state" do
      @creative.data["trigger"]["loop"].delete("source")
      @creative.save!
      before = @creative.data.deep_dup
      TriggerLoopCheckJob.stub(:perform_later, ->(*) { raise ActiveJob::EnqueueError }) do
        assert_raises(ActiveJob::EnqueueError) { @task.send(:check_trigger_loop_completion) }
      end
      assert_equal before, @creative.reload.data
    end

    [ "paused", "replacement", "next_turn" ].each do |change|
      test "check enqueue failure preserves concurrent #{change}" do
        enqueue = lambda do |*|
          config = @creative.reload.data.dig("trigger", "loop").deep_dup
          case change
          when "paused" then config["state"] = "paused"
          when "replacement"
            config["start_comment_id"] = @turn.id + 1
            config["generation"] += 1
          when "next_turn" then config["current_comment_id"] = @turn.id + 1
          end
          @creative.update!(data: { "trigger" => { "loop" => config } })
          false
        end
        TriggerLoopCheckJob.stub(:perform_later, enqueue) { @task.done! }
        config = @creative.reload.data.dig("trigger", "loop")
        assert_equal change == "paused" ? "paused" : "running", config["state"]
        assert_equal @turn.id + 1, config["start_comment_id"] if change == "replacement"
        assert_equal @turn.id + 1, config["current_comment_id"] if change == "next_turn"
      end
    end
  end
end
