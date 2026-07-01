# frozen_string_literal: true

require "test_helper"

module CollavreLinear
  class OutboundCommentUpdateJobTest < ActiveSupport::TestCase
    # Plain stub conforming to Client's public comment interface — no network.
    class FakeClient
      attr_reader :update_calls

      def initialize(response: { id: "lin-cmt-1" })
        @response     = response
        @update_calls = []
      end

      def update_comment(id:, body:)
        @update_calls << { id: id, body: body }
        @response
      end
    end

    def setup
      @user = Collavre.user_class.create!(
        email: "cmt-upd-#{SecureRandom.hex(4)}@example.com",
        name: "Comment Update Test",
        password: TEST_PASSWORD,
        password_confirmation: TEST_PASSWORD,
        timezone: "UTC"
      )

      @account = CollavreLinear::Account.create!(
        user: @user,
        linear_uid: "uid-cupd-#{SecureRandom.hex(4)}",
        access_token: "tok-cupd"
      )

      @creative = Collavre::Creative.new(description: "<p>Task</p>", user: @user)
      @creative.skip_linear_sync = true
      @creative.save!

      @project_link = CollavreLinear::ProjectLink.create!(
        creative: @creative,
        account:  @account,
        linear_project_id: "proj-cupd",
        team_id:           "team-cupd"
      )

      @issue_link = CollavreLinear::IssueLink.create!(
        creative:        @creative,
        project_link:    @project_link,
        linear_issue_id: "iss-cupd",
        sync_state:      :synced
      )

      @comment = @creative.comments.new(content: "hello linear", user: @user)
      @comment.skip_linear_sync = true
      @comment.save!

      @fake_client = FakeClient.new
    end

    test "updates the linked Linear comment with the prefixed body" do
      CollavreLinear::CommentLink.create!(
        comment_id:        @comment.id,
        linear_comment_id: "lin-cmt-1",
        issue_link:        @issue_link
      )

      CollavreLinear::Client.stub(:new, @fake_client) do
        CollavreLinear::OutboundCommentUpdateJob.perform_now(@comment.id)
      end

      assert_equal 1, @fake_client.update_calls.size
      assert_equal "lin-cmt-1", @fake_client.update_calls.first[:id]
      assert_equal "\\[Comment Update Test\\]: hello linear", @fake_client.update_calls.first[:body]
    end

    test "no-op when the comment has no CommentLink" do
      CollavreLinear::Client.stub(:new, @fake_client) do
        CollavreLinear::OutboundCommentUpdateJob.perform_now(@comment.id)
      end

      assert_equal 0, @fake_client.update_calls.size
    end

    test "no-op when the comment was deleted before the job runs" do
      CollavreLinear::CommentLink.create!(
        comment_id:        @comment.id,
        linear_comment_id: "lin-cmt-1",
        issue_link:        @issue_link
      )
      id = @comment.id
      @comment.skip_linear_sync = true
      @comment.destroy

      assert_nothing_raised do
        CollavreLinear::Client.stub(:new, @fake_client) do
          CollavreLinear::OutboundCommentUpdateJob.perform_now(id)
        end
      end
      assert_equal 0, @fake_client.update_calls.size
    end
  end
end
