# frozen_string_literal: true

require "test_helper"

module CollavreLinear
  class OutboundCommentSyncJobTest < ActiveSupport::TestCase
    # Plain stub conforming to Client's public comment interface — no network.
    class FakeClient
      attr_reader :calls

      def initialize(response: { id: "lin-cmt-1", updatedAt: "2026-07-01T00:00:00Z" })
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
      assert_equal "iss-cjob", @fake_client.calls.first[:issue_id]
      # Body is prefixed with the author's display name so Linear readers can tell
      # Collavre chat participants apart (all sync through one Linear app actor).
      # Brackets are escaped so Linear's Markdown does not read the prefix as a
      # link reference definition (which swallows single-word content to empty).
      assert_equal "\\[Comment Job Test\\]: hello linear", @fake_client.calls.first[:body]

      link = CollavreLinear::CommentLink.find_by(comment_id: @comment.id)
      assert_not_nil link
      assert_equal "lin-cmt-1", link.linear_comment_id
      assert_equal @issue_link.id, link.issue_link_id
      # The synced baseline is stored so the inbound applier can recognise this
      # comment's own create webhook (and stale echoes) by timestamp.
      assert_equal Time.utc(2026, 7, 1), link.remote_updated_at
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

    test "no-op when the comment was made private after the create was enqueued" do
      # The comment was public/Main when the observer enqueued this create job,
      # so no CommentLink exists yet and the observer cannot enqueue a delete for
      # the later visibility change. Posting the now-hidden body would leak it —
      # the job must re-run syncability and no-op.
      @comment.update_columns(private: true)

      CollavreLinear::Client.stub(:new, @fake_client) do
        CollavreLinear::OutboundCommentSyncJob.perform_now(@comment.id)
      end

      assert_equal 0, @fake_client.calls.size,
        "must not post a comment that is no longer public/Main"
      assert_nil CollavreLinear::CommentLink.find_by(comment_id: @comment.id)
    end

    test "no-op when the comment was moved out of Main after the create was enqueued" do
      other_topic = Collavre::Topic.create!(creative: @creative, user: @user, name: "Side thread")
      @comment.update_columns(topic_id: other_topic.id)

      CollavreLinear::Client.stub(:new, @fake_client) do
        CollavreLinear::OutboundCommentSyncJob.perform_now(@comment.id)
      end

      assert_equal 0, @fake_client.calls.size,
        "must not post a comment moved to a side topic"
      assert_nil CollavreLinear::CommentLink.find_by(comment_id: @comment.id)
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

    test "adopts the self-echo CommentLink and removes the mirror duplicate on collision" do
      # Simulate the inbound self-echo winning the race: in the window between
      # create_comment returning and our CommentLink.create!, Linear's create
      # webhook already mirrored the comment locally and grabbed the unique
      # linear_comment_id we are about to record.
      mirror = @creative.comments.new(content: "hello linear", user: @user)
      mirror.skip_linear_sync = true
      mirror.save!
      CollavreLinear::CommentLink.create!(
        comment_id:        mirror.id,
        linear_comment_id: "lin-cmt-1", # same id FakeClient returns
        issue_link:        @issue_link
      )

      assert_nothing_raised do
        CollavreLinear::Client.stub(:new, @fake_client) do
          CollavreLinear::OutboundCommentSyncJob.perform_now(@comment.id)
        end
      end

      # The link is adopted onto the user's original comment (so future edits keep
      # syncing instead of re-posting), and the echo mirror is removed — the
      # comment is neither double-represented nor left unlinked.
      link = CollavreLinear::CommentLink.find_by(linear_comment_id: "lin-cmt-1")
      assert_not_nil link
      assert_equal @comment.id, link.comment_id
      assert_equal 1, CollavreLinear::CommentLink.where(linear_comment_id: "lin-cmt-1").count
      assert_nil Collavre::Comment.find_by(id: mirror.id), "duplicate mirror must be removed"
    end
  end
end
