require "test_helper"

module Collavre
  module Comments
    class ResendsControllerTest < ActionDispatch::IntegrationTest
      setup do
        @user = users(:one)
        @creative = Creative.create!(user: @user, description: "Resend test")
        @comment = @creative.comments.create!(user: @user, content: "@AI Bot: try again")
        sign_in_as @user, password: "password"
      end

      test "recreates the message and dispatches a normal event only once" do
        events = []
        SystemEvents::Dispatcher.stub :dispatch, ->(name, context, **_options) { events << [ name, context ] } do
          post creative_comment_resend_path(@creative, @comment)
          assert_response :created
          replacement = Comment.find(response.parsed_body["id"])
          assert_equal @comment.content, replacement.content
          assert_equal @comment.topic_id, replacement.topic_id
          assert_not Comment.exists?(@comment.id)
          assert_equal 1, events.count { |name, context| name == "comment_created" && context[:comment][:id] == replacement.id }
          post creative_comment_resend_path(@creative, @comment)
          assert_response :not_found
        end
      end

      test "rejects another person's message" do
        @comment.update!(user: users(:two))
        assert_no_difference("Comment.count") { post creative_comment_resend_path(@creative, @comment) }
        assert_response :forbidden
      end

      test "disables inbox System resend in rendered messages and rejects direct requests" do
        inbox = Creative.inbox_for(@user)
        topic = inbox.system_topic(fallback_user: @user)
        reply = inbox.comments.create!(user: @user, topic: topic, content: "Inbox reply")
        get creative_comments_path(inbox), params: { topic_id: topic.id }
        assert_response :success
        assert_select "#comment_#{reply.id}[data-inbox-system='true']"

        assert_no_difference("Comment.count") { post creative_comment_resend_path(inbox, reply) }
        assert_response :forbidden
        assert Comment.exists?(reply.id)
      end

      test "disables command resend and rejects direct requests without dispatch or deletion" do
        [ '/topic "New"', '/compress', '/calendar list', '/custom_tool {}' ].each do |command|
          @comment.update_columns(content: "  #{command}\n\nCommand result")
          reply = @creative.comments.create!(user: users(:ai_bot), content: "Keep reply", topic_id: @comment.topic_id)
          get creative_comments_path(@creative), params: { topic_id: @comment.topic_id }
          assert_response :success
          assert_select "#comment_#{@comment.id}[data-command-message='true']"

          SystemEvents::Dispatcher.stub :dispatch, ->(*) { flunk "Dispatched command transcript" } do
            assert_no_difference("Comment.count") { post creative_comment_resend_path(@creative, @comment) }
          end
          assert_response :forbidden
          assert Comment.exists?(@comment.id)
          assert Comment.exists?(reply.id)
        end
      end

      test "disables private resend and preserves later public prompts replies and tasks" do
        @comment.update!(private: true)
        prompt = @creative.comments.create!(user: users(:two), content: "Public prompt", topic_id: @comment.topic_id)
        task = Task.create!(name: "Reply", agent: users(:ai_bot), creative: @creative,
                            topic_id: @comment.topic_id, status: "running")
        reply = @creative.comments.create!(user: users(:ai_bot), content: "Public reply",
                                          topic_id: @comment.topic_id, task: task)
        get creative_comments_path(@creative), params: { topic_id: @comment.topic_id }
        assert_response :success
        assert_select "#comment_#{@comment.id}[data-private='true']"
        assert_select "#comment_#{prompt.id}[data-private='false']"

        SystemEvents::Dispatcher.stub :dispatch, ->(*) { flunk "Dispatched private message" } do
          assert_no_difference("Comment.count") { post creative_comment_resend_path(@creative, @comment) }
        end
        assert_response :forbidden
        assert @comment.reload.private?
        assert_equal "Public prompt", prompt.reload.content
        assert_equal "Public reply", reply.reload.content
        assert_equal "running", task.reload.status
      end

      test "cannot address a message through another creative" do
        other = Creative.create!(user: @user, description: "Other")
        post creative_comment_resend_path(other, @comment)
        assert_response :not_found
      end

      test "requires authentication" do
        sign_out
        post creative_comment_resend_path(@creative, @comment)
        assert_response :redirect
        assert Comment.exists?(@comment.id)
      end

      test "returns a localized error for failed creation" do
        service = Object.new
        service.define_singleton_method(:call) { raise ActiveRecord::RecordInvalid }
        CommentResendService.stub :new, ->(**_args) { service } do
          post creative_comment_resend_path(@creative, @comment)
        end
        assert_response :unprocessable_entity
        assert_equal I18n.t("collavre.comments.resend_failed"), response.parsed_body["error"]
      end
    end
  end
end
