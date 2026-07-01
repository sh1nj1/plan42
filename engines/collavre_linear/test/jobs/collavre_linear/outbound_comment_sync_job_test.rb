# frozen_string_literal: true

require "test_helper"

module CollavreLinear
  class OutboundCommentSyncJobTest < ActiveSupport::TestCase
    # Plain stub conforming to Client's public comment interface — no network.
    class FakeClient
      attr_reader :calls

      def initialize(response: { id: "lin-cmt-1" })
        @response = response
        @calls    = []
      end

      def create_comment(issue_id:, body:)
        @calls << { issue_id: issue_id, body: body }
        @response
      end
    end

    def setup
      @user = Collavre.user_class.create!(
        email: "cmt-job-#{SecureRandom.hex(4)}@example.com",
        name: "Comment Job Test",
        password: TEST_PASSWORD,
        password_confirmation: TEST_PASSWORD,
        timezone: "UTC"
      )

      @account = CollavreLinear::Account.create!(
        user: @user,
        linear_uid: "uid-cjob-#{SecureRandom.hex(4)}",
        access_token: "tok-cjob"
      )

      @creative = Collavre::Creative.new(description: "<p>Task</p>", user: @user)
      @creative.skip_linear_sync = true
      @creative.save!

      @project_link = CollavreLinear::ProjectLink.create!(
        creative: @creative,
        account:  @account,
        linear_project_id: "proj-cjob",
        team_id:           "team-cjob"
      )

      @issue_link = CollavreLinear::IssueLink.create!(
        creative:        @creative,
        project_link:    @project_link,
        linear_issue_id: "iss-cjob",
        sync_state:      :synced
      )

      # Build the comment without echoing through the observer.
      @comment = @creative.comments.new(content: "hello linear", user: @user)
      @comment.skip_linear_sync = true
      @comment.save!

      @fake_client = FakeClient.new
    end

    test "posts the comment to Linear and creates a CommentLink" do
      CollavreLinear::Client.stub(:new, @fake_client) do
        CollavreLinear::OutboundCommentSyncJob.perform_now(@comment.id)
      end

      assert_equal 1, @fake_client.calls.size
      assert_equal "iss-cjob",     @fake_client.calls.first[:issue_id]
      assert_equal "hello linear", @fake_client.calls.first[:body]

      link = CollavreLinear::CommentLink.find_by(comment_id: @comment.id)
      assert_not_nil link
      assert_equal "lin-cmt-1", link.linear_comment_id
      assert_equal @issue_link.id, link.issue_link_id
    end

    test "is idempotent: an existing CommentLink short-circuits without posting" do
      CollavreLinear::CommentLink.create!(
        comment_id:        @comment.id,
        linear_comment_id: "already-linked",
        issue_link:        @issue_link
      )

      CollavreLinear::Client.stub(:new, @fake_client) do
        CollavreLinear::OutboundCommentSyncJob.perform_now(@comment.id)
      end

      assert_equal 0, @fake_client.calls.size, "must not re-post an already-linked comment"
      assert_equal 1, CollavreLinear::CommentLink.where(comment_id: @comment.id).count
    end

    test "no-op when the comment's creative has no Linear issue link" do
      unlinked = Collavre::Creative.new(description: "<p>Unlinked</p>", user: @user)
      unlinked.skip_linear_sync = true
      unlinked.save!
      comment = unlinked.comments.new(content: "orphan", user: @user)
      comment.skip_linear_sync = true
      comment.save!

      CollavreLinear::Client.stub(:new, @fake_client) do
        CollavreLinear::OutboundCommentSyncJob.perform_now(comment.id)
      end

      assert_equal 0, @fake_client.calls.size
      assert_nil CollavreLinear::CommentLink.find_by(comment_id: comment.id)
    end

    test "no-op when the comment was deleted before the job runs" do
      id = @comment.id
      @comment.destroy

      assert_nothing_raised do
        CollavreLinear::Client.stub(:new, @fake_client) do
          CollavreLinear::OutboundCommentSyncJob.perform_now(id)
        end
      end
      assert_equal 0, @fake_client.calls.size
    end
  end
end
