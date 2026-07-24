# frozen_string_literal: true

require "test_helper"

module Collavre
  class Comment
    class NotifiableTest < ActiveSupport::TestCase
      setup do
        @owner = users(:one)
        @agent = users(:two)
        # Make :two an AI user by setting llm_vendor
        @agent.update_columns(llm_vendor: "openai")

        @creative = Creative.create!(user: @owner, description: "Test Creative")
        @topic = Topic.create!(creative: @creative, name: "test", user: @owner)
      end

      test "notify_ai_completion notifies for an AI reply in a non-System inbox topic (Inbox#Main)" do
        # #1301 made every inbox topic EXCEPT System dispatch like a normal topic.
        # The System alarm must follow suit: an agent reply in Inbox#Main has to
        # notify the absent owner, otherwise Inbox#Main conversations are silent.
        inbox = Creative.inbox_for(@owner)
        main_topic = inbox.main_topic(fallback_user: @owner)
        system_topic = inbox.system_topic

        reply = inbox.comments.create!(
          content: Comment::STREAMING_PLACEHOLDER_CONTENT, user: @agent, topic: main_topic
        )
        reply.update!(content: "여기 결과입니다")

        assert_difference -> { inbox.comments.where(topic: system_topic).count }, 1 do
          reply.notify_ai_completion
        end
        notice = inbox.comments.where(topic: system_topic).order(:id).last
        assert_nil notice.user
        assert_equal reply.id, notice.quoted_comment_id
      end

      test "a system-authored Inbox#System notice does not cascade into another notification (loop guard)" do
        inbox = Creative.inbox_for(@owner)
        system_topic = inbox.system_topic

        # Creating the notice adds exactly itself (+1); its own callbacks must not
        # spawn a second notification, or the System topic would loop forever.
        assert_difference -> { inbox.comments.where(topic: system_topic).count }, 1 do
          Comment.create!(
            creative: inbox, topic: system_topic, content: "알림",
            user: nil, skip_default_user: true
          )
        end
      end

      test "notify_ai_completion creates inbox comment for absent users" do
        comment = @creative.comments.create!(
          content: Comment::STREAMING_PLACEHOLDER_CONTENT,
          user: @agent,
          topic: @topic
        )
        comment.update!(content: "AI response complete")

        inbox = Creative.inbox_for(@owner)

        assert_difference -> { inbox.comments.count }, 1 do
          comment.notify_ai_completion
        end

        inbox_comment = inbox.comments.order(:id).last
        assert_equal comment.id, inbox_comment.quoted_comment_id
        assert_nil inbox_comment.user
        assert_includes inbox_comment.content, "AI response complete"
      end

      test "notify_ai_completion sends mention notification as inbox comment for mentioned users" do
        @owner.update!(searchable: true)

        comment = @creative.comments.create!(
          content: Comment::STREAMING_PLACEHOLDER_CONTENT,
          user: @agent,
          topic: @topic
        )
        comment.update!(content: "Hello @#{@owner.name}: check this out")

        inbox = Creative.inbox_for(@owner)

        assert_difference -> { inbox.comments.count }, 1 do
          comment.notify_ai_completion
        end

        mention_comment = inbox.comments.order(:id).last
        assert_nil mention_comment.user
        assert_equal comment.id, mention_comment.quoted_comment_id
        assert_includes mention_comment.content, @agent.display_name
        assert_includes mention_comment.content, "check this out"
      end

      test "notify_ai_completion skips present users" do
        comment = @creative.comments.create!(
          content: "AI response complete",
          user: @agent,
          topic: @topic
        )

        inbox = Creative.inbox_for(@owner)
        CommentPresenceStore.add(@creative.id, @owner.id)

        assert_no_difference -> { inbox.comments.count } do
          comment.notify_ai_completion
        end
      ensure
        CommentPresenceStore.remove(@creative.id, @owner.id)
      end

      test "notify_ai_completion does nothing for non-AI users" do
        comment = @creative.comments.create!(
          content: "Human message",
          user: @owner,
          topic: @topic
        )

        inbox = Creative.inbox_for(@owner)

        assert_no_difference -> { inbox.comments.count } do
          comment.notify_ai_completion
        end
      end

      test "notify_ai_completion stores inbox comment content for long messages" do
        long_content = "A" * 200
        comment = @creative.comments.create!(
          content: long_content,
          user: @agent,
          topic: @topic
        )

        inbox = Creative.inbox_for(@owner)

        assert_difference -> { inbox.comments.count }, 1 do
          comment.notify_ai_completion
        end

        inbox_comment = inbox.comments.order(:id).last
        assert_nil inbox_comment.user
        assert_equal comment.id, inbox_comment.quoted_comment_id
        assert inbox_comment.content.present?
        assert_includes inbox_comment.content, long_content.first(50)
      end

      test "notify_ai_completion rescues errors without raising" do
        comment = @creative.comments.create!(
          content: "AI response",
          user: @agent,
          topic: @topic
        )

        comment.stub(:create_inbox_comment, ->(*_args) { raise StandardError, "test error" }) do
          assert_nothing_raised do
            comment.notify_ai_completion
          end
        end
      end
    end
  end
end
