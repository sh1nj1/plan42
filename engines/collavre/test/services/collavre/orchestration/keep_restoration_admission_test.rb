# frozen_string_literal: true

require "test_helper"

module Collavre
  module Orchestration
    class KeepRestorationAdmissionTest < ActiveSupport::TestCase
      setup do
        @creative = creatives(:tshirt)
        @agent = users(:ai_bot)
        @topic = @creative.main_topic
        @anchor = @creative.comments.create!(content: "Covering turn", user: users(:one), topic: @topic, skip_dispatch: true)
        @turn = @creative.comments.create!(content: "Keep turn", user: users(:one), topic: @topic, skip_dispatch: true)
        @config = TriggerLoopConfig.build(@topic.id, source: "keep", start_comment_id: @turn.id, current_comment_id: @turn.id)
        @creative.update!(data: { "trigger" => { "loop" => @config } })
        @task = Task.create!(name: "Covering task", status: "running", agent: @agent, creative: @creative,
          topic_id: @topic.id, trigger_event_name: "comment_created", trigger_event_payload: @anchor.dispatch_payload.deep_stringify_keys)
        assert DeliveryRecord.claim_drop!(@task, @turn.id)
      end

      test "replacement keep does not restore a superseded turn" do
        replacement = @config.merge("start_comment_id" => @turn.id + 1, "current_comment_id" => @turn.id + 1)
        @creative.update!(data: { "trigger" => { "loop" => replacement } })
        AiAgentJob.stub(:perform_later, ->(*) { flunk "Superseded keep was enqueued" }) do
          Matcher.stub(:permits_creative_access?, true) { @task.update!(status: "failed") }
        end
        assert_equal replacement, @creative.reload.data.dig("trigger", "loop")
        assert_includes DeliveryRecord.rejected_restore_ids_in(@task.reload.trigger_event_payload), @turn.id
        KeepLoop.stub(:admit!, ->(*) { flunk "Rejected obsolete restore was swept again" }) { DeliveryRecord.restore!(@task) }
      end

      test "late drop retains the original dispatch generation after replacement" do
        original_context = @turn.reload.dispatch_payload.deep_stringify_keys
        replacement = @config.merge("start_comment_id" => @turn.id + 1, "current_comment_id" => @turn.id + 1)
        @creative.update!(data: { "trigger" => { "loop" => replacement } })
        # Emulate a queued job reaching the late-drop gate for the first time.
        @task.update_columns(trigger_event_payload: @anchor.dispatch_payload.deep_stringify_keys)
        assert DeliveryRecord.claim_drop!(@task, @turn.id, context: original_context)
        AiAgentJob.stub(:perform_later, ->(*) { flunk "Late superseded keep was enqueued" }) do
          Matcher.stub(:permits_creative_access?, true) { @task.update!(status: "failed") }
        end
        assert_equal replacement, @creative.reload.data.dig("trigger", "loop")
      end

      test "paused keep does not restore work" do
        @creative.update!(data: { "trigger" => { "loop" => @config.merge("state" => "paused") } })
        AiAgentJob.stub(:perform_later, ->(*) { flunk "Paused keep was enqueued" }) do
          Matcher.stub(:permits_creative_access?, true) { @task.update!(status: "failed") }
        end
        assert_equal "paused", @creative.reload.data.dig("trigger", "loop", "state")
      end

      test "acknowledged current keep restoration retains ownership and strips drop metadata" do
        enqueued = []
        Matcher.stub(:permits_creative_access?, true) do
          AiAgentJob.stub(:perform_later, ->(*args) { enqueued << args; true }) { @task.update!(status: "failed") }
        end
        assert_equal 1, enqueued.size
        refute enqueued.first.last.key?(KeepDispatchRestoration::KEY)
        assert_equal [ @turn.id ], DeliveryRecord.restored_ids_in(@task.reload.trigger_event_payload)
        assert_equal "running", @creative.reload.data.dig("trigger", "loop", "state")
      end

      test "rejected ordinary restoration remains retryable in the same keep topic" do
        ordinary = @creative.comments.create!(content: "Unrelated dispatch", user: users(:one), topic: @topic, skip_dispatch: true)
        assert DeliveryRecord.claim_drop!(@task, ordinary.id)
        @task.update_columns(status: "failed")
        Matcher.stub(:permits_creative_access?, true) do
          AiAgentJob.stub(:perform_later, false) { DeliveryRecord.restore!(@task) }
        end
        assert_empty DeliveryRecord.restored_ids_in(@task.reload.trigger_event_payload)
        refute_includes DeliveryRecord.rejected_restore_ids_in(@task.trigger_event_payload), ordinary.id
        assert DeliveryRecord.claim_restore!(@task, ordinary.id)
      end

      test "rejected restoration enqueue releases its claim and current keep turn" do
        Matcher.stub(:permits_creative_access?, true) do
          AiAgentJob.stub(:perform_later, false) { @task.update!(status: "failed") }
        end
        assert_empty DeliveryRecord.restored_ids_in(@task.reload.trigger_event_payload)
        assert_equal "awaiting_user", @creative.reload.data.dig("trigger", "loop", "state")
      end
    end
  end
end
