# frozen_string_literal: true

require "test_helper"

module Collavre
  class DropTriggerJobTest < ActiveSupport::TestCase
    include ActiveJob::TestHelper

    setup do
      @owner = users(:one)
      @ai_bot = users(:ai_bot)
      Current.session = OpenStruct.new(user: @owner)

      perform_enqueued_jobs do
        @parent = Creative.create!(user: @owner, description: "Trigger Parent", data: { "trigger" => { "on_child_enter" => true } })
        @child = Creative.create!(user: @owner, description: "Dropped Child")
        CreativeShare.create!(creative: @parent, user: @ai_bot, permission: :write)
      end
    end

    teardown do
      Current.reset
    end

    test "creates trigger topic and comment on child creative" do
      SystemEvents::Dispatcher.stub(:dispatch, [ @ai_bot ]) do
        assert_difference -> { @child.comments.count }, 1 do
          assert_difference -> { @child.topics.count }, 1 do
            DropTriggerJob.perform_now(@parent.id, @child.id)
          end
        end
      end

      topic = @child.topics.find_by(name: "Drop Trigger")
      assert topic, "Drop Trigger topic should be created on child"

      comment = @child.comments.last
      assert_includes comment.content, "@#{@ai_bot.name}:"
      assert_includes comment.content, @child.creative_snippet
    end

    test "reuses existing Drop Trigger topic" do
      SystemEvents::Dispatcher.stub(:dispatch, [ @ai_bot ]) do
        DropTriggerJob.perform_now(@parent.id, @child.id)
      end
      topic = @child.topics.find_by(name: "Drop Trigger")

      SystemEvents::Dispatcher.stub(:dispatch, [ @ai_bot ]) do
        assert_no_difference -> { @child.topics.count } do
          DropTriggerJob.perform_now(@parent.id, @child.id)
        end
      end

      assert_equal topic.id, @child.topics.find_by(name: "Drop Trigger").id
    end

    test "skips when parent trigger is disabled" do
      @parent.update!(data: {})

      assert_no_difference -> { Comment.count } do
        DropTriggerJob.perform_now(@parent.id, @child.id)
      end
    end

    test "posts failure notice when no AI agent found" do
      CreativeShare.where(creative: @parent, user: @ai_bot).destroy_all

      assert_difference -> { @child.comments.count }, 1 do
        DropTriggerJob.perform_now(@parent.id, @child.id)
      end

      comment = @child.comments.last
      assert_nil comment.user_id, "Failure notice should be a system message (user_id: nil)"
      assert_includes comment.content, "⚠️"
      assert_includes comment.content, @parent.creative_snippet
    end

    test "skips when parent creative not found" do
      assert_no_difference -> { Comment.count } do
        DropTriggerJob.perform_now(0, @child.id)
      end
    end

    test "skips when child creative not found" do
      assert_no_difference -> { Comment.count } do
        DropTriggerJob.perform_now(@parent.id, 0)
      end
    end

    test "comment mentions the AI agent for routing" do
      SystemEvents::Dispatcher.stub(:dispatch, [ @ai_bot ]) do
        DropTriggerJob.perform_now(@parent.id, @child.id)
      end

      comment = @child.comments.last
      assert comment.content.start_with?("@#{@ai_bot.name}:"),
        "Comment should start with @AgentName: mention"
    end

    test "uses creative_snippet for plain text names" do
      @child.update!(description: "<p>HTML <strong>description</strong> that is very long and should be truncated</p>")

      SystemEvents::Dispatcher.stub(:dispatch, [ @ai_bot ]) do
        DropTriggerJob.perform_now(@parent.id, @child.id)
      end

      comment = @child.comments.last
      refute_includes comment.content, "<p>"
      refute_includes comment.content, "<strong>"
    end

    test "posts failure notice when dispatch schedules no agent" do
      SystemEvents::Dispatcher.stub(:dispatch, []) do
        assert_difference -> { @child.comments.count }, 2 do
          DropTriggerJob.perform_now(@parent.id, @child.id)
        end
      end

      comments = @child.comments.order(:id).last(2)
      assert_includes comments.first.content, "@#{@ai_bot.name}:"
      assert_nil comments.last.user_id
      assert_includes comments.last.content, "⚠️"
    end
  end
end
