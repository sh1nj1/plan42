# frozen_string_literal: true

require "test_helper"

module CollavreLinear
  class CommentSyncObserverTest < ActiveSupport::TestCase
    include ActiveJob::TestHelper

    def setup
      @original_adapter = ActiveJob::Base.queue_adapter
      ActiveJob::Base.queue_adapter = :test

      @user = Collavre.user_class.create!(
        email: "comment-obs-#{SecureRandom.hex(4)}@example.com",
        name: "Comment Observer Test",
        password: TEST_PASSWORD,
        password_confirmation: TEST_PASSWORD,
        timezone: "UTC"
      )

      @account = CollavreLinear::Account.create!(
        user: @user,
        linear_uid: "uid-cobs-#{SecureRandom.hex(4)}",
        access_token: "tok-cobs"
      )

      # A creative linked to a Linear issue: comments on it should sync out.
      @creative = Collavre::Creative.new(description: "<p>Task</p>", user: @user)
      @creative.skip_linear_sync = true
      @creative.save!

      @project_link = CollavreLinear::ProjectLink.create!(
        creative: @creative,
        account:  @account,
        linear_project_id: "proj-cobs",
        team_id:           "team-cobs"
      )

      @issue_link = CollavreLinear::IssueLink.create!(
        creative:        @creative,
        project_link:    @project_link,
        linear_issue_id: "iss-cobs",
        sync_state:      :synced
      )
    end

    def teardown
      ActiveJob::Base.queue_adapter = @original_adapter
    end

    test "human Main-topic comment on a linked creative enqueues OutboundCommentSyncJob once" do
      comment = nil
      assert_enqueued_jobs 1, only: CollavreLinear::OutboundCommentSyncJob do
        comment = @creative.comments.create!(content: "hello linear", user: @user)
      end

      assert_enqueued_with(job: CollavreLinear::OutboundCommentSyncJob, args: [ comment.id ])
    end

    test "comment on an unlinked creative enqueues nothing" do
      other = Collavre::Creative.new(description: "<p>Unlinked</p>", user: @user)
      other.skip_linear_sync = true
      other.save!

      assert_no_enqueued_jobs only: CollavreLinear::OutboundCommentSyncJob do
        other.comments.create!(content: "no sync", user: @user)
      end
    end

    test "comment outside the Main topic enqueues nothing" do
      side_topic = @creative.topics.create!(name: "Side", user: @user)

      assert_no_enqueued_jobs only: CollavreLinear::OutboundCommentSyncJob do
        @creative.comments.create!(content: "side note", user: @user, topic: side_topic)
      end
    end

    test "private comment enqueues nothing" do
      assert_no_enqueued_jobs only: CollavreLinear::OutboundCommentSyncJob do
        @creative.comments.create!(content: "secret", user: @user, private: true)
      end
    end

    test "system comment without a user enqueues nothing" do
      assert_no_enqueued_jobs only: CollavreLinear::OutboundCommentSyncJob do
        @creative.comments.create!(content: "system notice", user: nil, skip_default_user: true)
      end
    end

    test "AI agent comment enqueues nothing (streaming placeholder guard)" do
      ai_user = Collavre.user_class.create!(
        email: "ai-#{SecureRandom.hex(4)}@example.com",
        name: "AI Agent",
        password: TEST_PASSWORD,
        password_confirmation: TEST_PASSWORD,
        timezone: "UTC",
        llm_vendor: "openclaw"
      )

      assert_no_enqueued_jobs only: CollavreLinear::OutboundCommentSyncJob do
        @creative.comments.create!(content: "agent reply", user: ai_user)
      end
    end

    test "inbound-mirrored comment (skip_linear_sync) does not echo back out" do
      assert_no_enqueued_jobs only: CollavreLinear::OutboundCommentSyncJob do
        comment = @creative.comments.new(content: "from linear", user: @user)
        comment.skip_linear_sync = true
        comment.save!
      end
    end

    # -- outbound update -------------------------------------------------------

    test "editing a synced comment's content enqueues OutboundCommentUpdateJob once" do
      comment = synced_comment

      assert_enqueued_jobs 1, only: CollavreLinear::OutboundCommentUpdateJob do
        comment.update!(content: "edited")
      end

      assert_enqueued_with(job: CollavreLinear::OutboundCommentUpdateJob, args: [ comment.id ])
    end

    test "link preview formatting enqueues an update for an existing Linear comment" do
      comment = synced_comment(content: "https://example.com/linear-preview")
      expected_revision = comment.notification_revision
      clear_enqueued_jobs
      formatter = Minitest::Mock.new
      formatter.expect(:format, "[Preview](https://example.com/linear-preview)")

      Collavre::CommentLinkFormatter.stub(:new, formatter) do
        assert_enqueued_jobs 1, only: CollavreLinear::OutboundCommentUpdateJob do
          Collavre::CommentLinkPreviewJob.perform_now(
            comment.id,
            comment.content,
            expected_revision
          )
        end
      end

      assert_equal "[Preview](https://example.com/linear-preview)", comment.reload.content
      assert_equal expected_revision, comment.notification_revision
      assert_no_enqueued_jobs only: Collavre::CommentLinkPreviewJob
      formatter.verify
    end

    test "editing a comment with no CommentLink enqueues no outbound update" do
      unsynced = @creative.comments.new(content: "unsynced", user: @user)
      unsynced.skip_linear_sync = true
      unsynced.save!
      fresh = ::Collavre::Comment.find(unsynced.id)

      assert_no_enqueued_jobs only: CollavreLinear::OutboundCommentUpdateJob do
        fresh.update!(content: "edited")
      end
    end

    test "saving a synced comment without changing content enqueues no outbound update" do
      comment = synced_comment(content: "hello linear")

      assert_no_enqueued_jobs only: CollavreLinear::OutboundCommentUpdateJob do
        comment.update!(content: "hello linear")
      end
    end

    test "inbound-mirrored content edit (skip_linear_sync) does not echo an update" do
      comment = synced_comment
      comment.skip_linear_sync = true

      assert_no_enqueued_jobs only: CollavreLinear::OutboundCommentUpdateJob do
        comment.update!(content: "from a linear edit")
      end
    end

    test "editing a mirrored comment to private removes its Linear mirror instead of updating it" do
      comment = synced_comment
      link = CollavreLinear::CommentLink.find_by(comment_id: comment.id)

      comment.update!(content: "now secret", private: true)

      assert_equal 0, enqueued_jobs.count { |j| j[:job] == CollavreLinear::OutboundCommentUpdateJob },
        "must not push a now-private comment body out to Linear"
      delete_jobs = enqueued_jobs.select { |j| j[:job] == CollavreLinear::OutboundCommentDeleteJob }
      assert_equal 1, delete_jobs.size, "turning private must remove the Linear mirror"
      assert_equal [ link.id ], delete_jobs.first[:args]
    end

    test "moving a mirrored comment out of the Main topic removes its Linear mirror" do
      comment = synced_comment
      link = CollavreLinear::CommentLink.find_by(comment_id: comment.id)
      side_topic = @creative.topics.create!(name: "Side", user: @user)

      comment.update!(topic: side_topic)

      assert_equal 0, enqueued_jobs.count { |j| j[:job] == CollavreLinear::OutboundCommentUpdateJob }
      delete_jobs = enqueued_jobs.select { |j| j[:job] == CollavreLinear::OutboundCommentDeleteJob }
      assert_equal 1, delete_jobs.size, "moving out of Main must remove the Linear mirror"
      assert_equal [ link.id ], delete_jobs.first[:args]
    end

    test "a comment made private then public again re-mirrors to Linear" do
      comment = synced_comment
      link = CollavreLinear::CommentLink.find_by(comment_id: comment.id)

      # Going private enqueues the delete job; simulate it tearing down the link.
      comment.update!(private: true)
      link.destroy

      # Re-entering syncable state with the mirror gone must recreate it, not
      # leave the (now visible again) comment permanently absent from Linear.
      fresh = ::Collavre::Comment.find(comment.id)
      assert_enqueued_jobs 1, only: CollavreLinear::OutboundCommentSyncJob do
        fresh.update!(private: false)
      end
      assert_enqueued_with(job: CollavreLinear::OutboundCommentSyncJob, args: [ fresh.id ])
    end

    # -- outbound delete -------------------------------------------------------

    test "deleting a synced comment enqueues OutboundCommentDeleteJob once" do
      comment = synced_comment
      link = CollavreLinear::CommentLink.find_by(comment_id: comment.id)

      assert_enqueued_jobs 1, only: CollavreLinear::OutboundCommentDeleteJob do
        comment.destroy
      end

      # Assert against the raw enqueued args rather than assert_enqueued_with:
      # the latter deserializes every enqueued job, and the comment's own
      # cancel_pending_tasks job holds a GlobalID to the now-destroyed comment,
      # which can no longer be resolved.
      delete_job = enqueued_jobs.find { |j| j[:job] == CollavreLinear::OutboundCommentDeleteJob }
      assert_equal [ link.id ], delete_job[:args]
    end

    test "deleting a comment with no CommentLink enqueues no outbound delete" do
      unsynced = @creative.comments.new(content: "unsynced", user: @user)
      unsynced.skip_linear_sync = true
      unsynced.save!
      fresh = ::Collavre::Comment.find(unsynced.id)

      assert_no_enqueued_jobs only: CollavreLinear::OutboundCommentDeleteJob do
        fresh.destroy
      end
    end

    test "inbound-mirrored delete (skip_linear_sync) does not echo a delete" do
      comment = synced_comment
      comment.skip_linear_sync = true

      assert_no_enqueued_jobs only: CollavreLinear::OutboundCommentDeleteJob do
        comment.destroy
      end
    end

    private

    # A comment already mirrored to Linear (has a CommentLink). Returns a fresh
    # instance so the transient skip_linear_sync used to suppress the create echo
    # does not carry over into the update/delete assertions.
    def synced_comment(content: "hello linear")
      comment = @creative.comments.new(content: content, user: @user)
      comment.skip_linear_sync = true
      comment.save!
      CollavreLinear::CommentLink.create!(
        comment_id:        comment.id,
        linear_comment_id: "lin-#{comment.id}",
        issue_link:        @issue_link
      )
      ::Collavre::Comment.find(comment.id)
    end
  end
end
