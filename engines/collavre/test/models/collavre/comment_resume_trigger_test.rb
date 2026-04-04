# frozen_string_literal: true

require "test_helper"

module Collavre
  class CommentResumeTriggerTest < ActiveSupport::TestCase
    setup do
      @human = users(:one)
      @ai_bot = users(:ai_bot)

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

      @child = Creative.create!(
        description: "Child task",
        user: @human
      )
      Creative.where(id: @child.id).update_all(parent_id: @parent.id)
      @child.reload

      @topic = @child.topics.create!(name: "Drop Trigger", user: @human)

      @child.update!(data: {
        "trigger" => {
          "loop" => {
            "state" => "awaiting_user",
            "current_iteration" => 2,
            "max_iterations" => 10,
            "trigger_topic_id" => @topic.id
          }
        }
      })
    end

    test "human comment in trigger topic resumes awaiting_user loop" do
      SystemEvents::Dispatcher.stub(:dispatch, ->(*_args) { [ @ai_bot ] }) do
        assert_difference -> { @child.comments.count }, 2 do
          # 1 = the human comment itself, 2 = the auto-posted resume instruction
          @child.comments.create!(
            content: "Approved, go ahead",
            topic_id: @topic.id,
            user: @human
          )
        end
      end

      @child.reload
      assert_equal "running", @child.data.dig("trigger", "loop", "state")
      resume_comment = @child.comments.order(:created_at).last
      assert_includes resume_comment.content, "@#{@ai_bot.name}:"
      assert_includes resume_comment.content, "🔄"
    end

    test "AI comment does not resume awaiting_user loop" do
      SystemEvents::Dispatcher.stub(:dispatch, ->(*_args) { [] }) do
        assert_difference -> { @child.comments.count }, 1 do
          @child.comments.create!(
            content: "Still waiting for user",
            topic_id: @topic.id,
            user: @ai_bot
          )
        end
      end

      @child.reload
      assert_equal "awaiting_user", @child.data.dig("trigger", "loop", "state")
    end

    test "human comment in different topic does not resume loop" do
      other_topic = @child.topics.create!(name: "General", user: @human)

      SystemEvents::Dispatcher.stub(:dispatch, ->(*_args) { [] }) do
        assert_difference -> { @child.comments.count }, 1 do
          @child.comments.create!(
            content: "Some unrelated comment",
            topic_id: other_topic.id,
            user: @human
          )
        end
      end

      @child.reload
      assert_equal "awaiting_user", @child.data.dig("trigger", "loop", "state")
    end

    test "human comment does not resume when loop is in running state" do
      @child.data["trigger"]["loop"]["state"] = "running"
      @child.save!

      SystemEvents::Dispatcher.stub(:dispatch, ->(*_args) { [] }) do
        assert_difference -> { @child.comments.count }, 1 do
          @child.comments.create!(
            content: "Some comment",
            topic_id: @topic.id,
            user: @human
          )
        end
      end

      @child.reload
      assert_equal "running", @child.data.dig("trigger", "loop", "state")
    end
  end
end
