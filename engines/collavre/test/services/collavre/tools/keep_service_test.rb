# frozen_string_literal: true

require "test_helper"

module Collavre
  module Tools
    class KeepServiceTest < ActiveSupport::TestCase
      setup do
        @owner = users(:one)
        @creative = Creative.create!(description: "Keep host", user: @owner)
        @topic = @creative.topics.create!(name: "Work", user: @owner)
        Current.user = @owner
      end

      teardown { Current.reset }

      test "starts a loop using only the topic identity and preserves reserved goal text" do
        result = KeepService.new.call(max: 3, goal: "@Unknown: --max 50", topic_id: @topic.id)
        assert_equal @topic.id, result[:topic_id]
        assert_equal @creative.id, result[:creative_id]
        loop_data = @creative.reload.data.dig("trigger", "loop")
        assert_equal 3, loop_data["max_iterations"]
        assert_equal "@Unknown: --max 50", loop_data["goal"]
      end

      test "defaults to ten iterations and permits an empty goal" do
        assert KeepService.new.call(topic_id: @topic.id)[:id]
        assert_equal 10, @creative.reload.data.dig("trigger", "loop", "max_iterations")
      end

      test "accepts the maximum limit" do
        assert KeepService.new.call(max: 1000, topic_id: @topic.id)[:id]
        assert_equal 1000, @creative.reload.data.dig("trigger", "loop", "max_iterations")
      end

      test "rejects invalid limits without creating a comment or loop" do
        [ 0, 1001 ].each do |limit|
          assert_no_difference "Comment.count" do
            assert_raises(ArgumentError) { KeepService.new.call(max: limit, topic_id: @topic.id) }
          end
        end
        assert_nil @creative.reload.data["trigger"]
      end

      test "requires write permission even when the caller can post feedback" do
        reader = users(:two)
        CreativeShare.create!(creative: @creative, user: reader, permission: :feedback)
        Current.user = reader
        assert_no_difference "Comment.count" do
          assert_raises(PermissionDeniedError) { KeepService.new.call(topic_id: @topic.id) }
        end
      end

      test "rejects an unknown selected agent" do
        assert_no_difference "Comment.count" do
          assert_raises(ArgumentError) { KeepService.new.call(agent_name: "Unknown", topic_id: @topic.id) }
        end
      end

      test "selected agent is stored and the initial turn uses that agent" do
        agent = users(:ai_bot)
        CreativeShare.create!(creative: @creative, user: agent, permission: :feedback)
        result = SystemEvents::Dispatcher.stub(:dispatch, []) do
          KeepService.new.call(agent_name: agent.name, goal: "Finish", topic_id: @topic.id)
        end
        assert_equal agent.id, @creative.reload.data.dig("trigger", "loop", "agent_id")
        assert_includes result[:content], "@#{agent.name}:"
      end

      test "agent author uses the existing A2A dispatch path" do
        agent = users(:ai_bot)
        CreativeShare.create!(creative: @creative, user: agent, permission: :write)
        Current.user = agent
        events = []
        SystemEvents::Dispatcher.stub(:dispatch, ->(event, payload, **options) {
          assert options[:require_enqueue_ack]
          events << options[:source]
          []
        }) do
          KeepService.new.call(goal: "Finish", topic_id: @topic.id)
        end
        assert_equal [ "a2a" ], events
        assert_equal @topic.id, @creative.reload.data.dig("trigger", "loop", "trigger_topic_id")
      end

      test "AI dispatch without eligible agents pauses the loop" do
        prepare_ai_caller
        SystemEvents::Dispatcher.stub(:dispatch, []) do
          KeepService.new.call(topic_id: @topic.id)
        end
        assert_equal "awaiting_user", @creative.reload.data.dig("trigger", "loop", "state")
      end

      test "AI dispatch exceptions pause the loop and propagate" do
        prepare_ai_caller
        SystemEvents::Dispatcher.stub(:dispatch, ->(*) { raise "dispatch failed" }) do
          error = assert_raises(RuntimeError) { KeepService.new.call(topic_id: @topic.id) }
          assert_equal "dispatch failed", error.message
        end
        assert_equal "awaiting_user", @creative.reload.data.dig("trigger", "loop", "state")
      end

      test "AI dispatch with an accepted agent keeps the loop running" do
        prepare_ai_caller
        SystemEvents::Dispatcher.stub(:dispatch, [ users(:two) ]) do
          KeepService.new.call(topic_id: @topic.id)
        end
        assert_equal "running", @creative.reload.data.dig("trigger", "loop", "state")
      end

      test "missing topic and closed topics cannot initialize a loop" do
        assert_raises(ActiveRecord::RecordNotFound) { KeepService.new.call }
        @topic.archive!
        assert_no_difference "Comment.count" do
          assert_raises(ArgumentError) { KeepService.new.call(topic_id: @topic.id) }
        end
        assert_nil @creative.reload.data["trigger"]
      end

      test "cannot replace an active loop" do
        KeepService.new.call(goal: "Original", topic_id: @topic.id)
        original = @creative.reload.data.dig("trigger", "loop")
        @creative.update!(data: @creative.data.deep_merge("trigger" => { "loop" => { "state" => "running" } }))
        assert_no_difference "Comment.count" do
          assert_raises(ActiveRecord::RecordInvalid) { KeepService.new.call(goal: "Replacement", topic_id: @topic.id) }
        end
        assert_equal original["goal"], @creative.reload.data.dig("trigger", "loop", "goal")
      end

      test "schema places required topic id last" do
        schema = ToolSchema::Builder.build(KeepService)
        assert_equal "topic_id", schema[:params].last[:name].to_s
        assert schema[:params].last[:required]
      end
      private

      def prepare_ai_caller
        agent = users(:ai_bot)
        CreativeShare.create!(creative: @creative, user: agent, permission: :write)
        Current.user = agent
      end
    end
  end
end
