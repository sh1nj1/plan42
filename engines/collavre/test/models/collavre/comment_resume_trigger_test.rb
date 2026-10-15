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

    test "dispatch-suppressed human comment does not resume awaiting_user loop" do
      SystemEvents::Dispatcher.stub(:dispatch, ->(*) { flunk "Suppressed comment dispatched" }) do
        assert_difference -> { @child.comments.count }, 1 do
          @child.comments.create!(content: "Synthetic instruction", topic: @topic,
            user: @human, skip_dispatch: true)
        end
      end
      assert_equal "awaiting_user", @child.reload.data.dig("trigger", "loop", "state")
    end

    # An approval surface (approve button / approved label = action payload) is a
    # human decision surface, not a "user resumed" signal. Even authored by a
    # human, it must not resume the loop — otherwise the auto-posted @agent
    # resume turn would carry the approval message into the agent's history,
    # routing around the dispatch-seam filter.
    test "human-authored approval-action comment does not resume awaiting_user loop" do
      SystemEvents::Dispatcher.stub(:dispatch, ->(*_args) { [] }) do
        assert_difference -> { @child.comments.count }, 1 do
          # only the comment itself; NO auto-posted resume instruction
          @child.comments.create!(
            content: "Approve tool?",
            topic_id: @topic.id,
            user: @human,
            approver: @human,
            action: JSON.generate("action" => "execute_tool", "tool_name" => "write_file")
          )
        end
      end

      @child.reload
      assert_equal "awaiting_user", @child.data.dig("trigger", "loop", "state")
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
    test "comment on creative without awaiting loop skips the lock and writes nothing" do
      @child.update!(data: {})
      comment = create_comment_without_callbacks(@topic)

      sql = capture_sql { comment.send(:resume_trigger_loop_if_awaiting) }

      assert_equal 1, sql.size, "expected only the precheck read, got: #{sql.inspect}"
      assert_match(/\ASELECT/i, sql.first)
      assert_equal({}, @child.reload.data)
    end

    test "awaiting loop in another topic is rejected before taking the lock" do
      other_topic = @child.topics.create!(name: "General", user: @human)
      comment = create_comment_without_callbacks(other_topic)

      sql = capture_sql { comment.send(:resume_trigger_loop_if_awaiting) }

      assert_equal 1, sql.size, "expected only the precheck read, got: #{sql.inspect}"
      assert_equal "awaiting_user", @child.reload.data.dig("trigger", "loop", "state")
    end

    test "awaiting loop without a recorded trigger topic resumes from any topic" do
      @child.data["trigger"]["loop"].delete("trigger_topic_id")
      @child.save!
      other_topic = @child.topics.create!(name: "General", user: @human)

      SystemEvents::Dispatcher.stub(:dispatch, ->(*_args) { [] }) do
        assert_difference -> { @child.comments.count }, 2 do
          @child.comments.create!(content: "Go on", topic_id: other_topic.id, user: @human)
        end
      end

      assert_equal "running", @child.reload.data.dig("trigger", "loop", "state")
    end

    test "precheck reads fresh state instead of the in-memory creative" do
      awaiting = @child.data.deep_dup
      @child.data["trigger"]["loop"]["state"] = "running"
      @child.save!
      comment = create_comment_without_callbacks(@topic)
      # The loop moves to awaiting_user after the comment's creative was
      # loaded, so the in-memory copy is stale (still says running).
      Creative.where(id: @child.id).update_all(data: awaiting)
      assert_equal "running", comment.creative.data.dig("trigger", "loop", "state")

      SystemEvents::Dispatcher.stub(:dispatch, ->(*_args) { [ @ai_bot ] }) do
        assert_difference -> { @child.comments.count }, 1 do
          comment.send(:resume_trigger_loop_if_awaiting)
        end
      end

      assert_equal "running", @child.reload.data.dig("trigger", "loop", "state")
    end

    test "state change between precheck and lock is re-checked under the lock" do
      comment = create_comment_without_callbacks(@topic)
      running = @child.data.deep_dup.tap { |d| d["trigger"]["loop"]["state"] = "running" }
      # Simulate a concurrent resume committing after the lock-free precheck
      # but before this comment acquires the row lock.
      creative = comment.creative
      creative.define_singleton_method(:with_lock) do |*args, &block|
        Creative.where(id: id).update_all(data: running)
        super(*args, &block)
      end

      assert_no_difference -> { @child.comments.count } do
        comment.send(:resume_trigger_loop_if_awaiting)
      end

      assert_equal "running", @child.reload.data.dig("trigger", "loop", "state")
      assert_equal 2, @child.data.dig("trigger", "loop", "current_iteration")
    end

    test "second human comment after a resume does not resume again" do
      SystemEvents::Dispatcher.stub(:dispatch, ->(*_args) { [] }) do
        assert_difference -> { @child.comments.count }, 3 do
          # first: comment + resume instruction; second: only the comment
          @child.comments.create!(content: "First", topic_id: @topic.id, user: @human)
          @child.comments.create!(content: "Second", topic_id: @topic.id, user: @human)
        end
      end

      resume_comments = @child.comments.where("content LIKE ?", "%🔄%")
      assert_equal 1, resume_comments.count
      assert_equal "running", @child.reload.data.dig("trigger", "loop", "state")
    end

    private

    def create_comment_without_callbacks(topic)
      SystemEvents::Dispatcher.stub(:dispatch, ->(*_args) { [] }) do
        @child.comments.create!(content: "Hello", topic_id: topic.id, user: @human, skip_dispatch: true)
      end
    end

    def capture_sql
      queries = []
      callback = lambda do |*, payload|
        next if payload[:name] == "SCHEMA" || payload[:cached]

        queries << payload[:sql]
      end
      ActiveSupport::Notifications.subscribed(callback, "sql.active_record") { yield }
      queries
    end
  end
end
