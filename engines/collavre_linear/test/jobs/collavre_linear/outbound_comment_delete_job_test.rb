# frozen_string_literal: true

require "test_helper"

module CollavreLinear
  class OutboundCommentDeleteJobTest < ActiveSupport::TestCase
    # Plain stub conforming to Client's public comment interface — no network.
    class FakeClient
      attr_reader :delete_calls

      def initialize(response: true)
        @response     = response
        @delete_calls = []
      end

      def delete_comment(id)
        @delete_calls << id
        @response
      end
    end

    def setup
      @user = Collavre.user_class.create!(
        email: "cmt-del-#{SecureRandom.hex(4)}@example.com",
        name: "Comment Delete Test",
        password: TEST_PASSWORD,
        password_confirmation: TEST_PASSWORD,
        timezone: "UTC"
      )

      @account = CollavreLinear::Account.create!(
        user: @user,
        linear_uid: "uid-cdel-#{SecureRandom.hex(4)}",
        access_token: "tok-cdel"
      )

      @creative = Collavre::Creative.new(description: "<p>Task</p>", user: @user)
      @creative.skip_linear_sync = true
      @creative.save!

      @project_link = CollavreLinear::ProjectLink.create!(
        creative: @creative,
        account:  @account,
        linear_project_id: "proj-cdel",
        team_id:           "team-cdel"
      )

      @issue_link = CollavreLinear::IssueLink.create!(
        creative:        @creative,
        project_link:    @project_link,
        linear_issue_id: "iss-cdel",
        sync_state:      :synced
      )

      # The comment is already gone by the time the delete job runs (destroy is a
      # hard delete), so the CommentLink is the job's only handle on it.
      @comment = @creative.comments.new(content: "gone", user: @user)
      @comment.skip_linear_sync = true
      @comment.save!
      @comment_id = @comment.id
      @comment.destroy

      @link = CollavreLinear::CommentLink.create!(
        comment_id:        @comment_id,
        linear_comment_id: "lin-del-1",
        issue_link:        @issue_link
      )

      @fake_client = FakeClient.new
    end

    test "deletes the Linear comment and destroys the CommentLink" do
      CollavreLinear::Client.stub(:new, @fake_client) do
        CollavreLinear::OutboundCommentDeleteJob.perform_now(@link.id)
      end

      assert_equal [ "lin-del-1" ], @fake_client.delete_calls
      assert_nil CollavreLinear::CommentLink.find_by(id: @link.id),
        "the CommentLink must be removed once the Linear comment is deleted"
    end

    test "keeps the mirror when the comment became visible again before the job ran" do
      # Re-visibility race: the comment went private / left Main (this delete was
      # enqueued), then became public/Main again before the job ran. Its
      # CommentLink still exists and the observer enqueues no recreate (only
      # private/topic_id changed, not content), so deleting the mirror now would
      # strand the re-visible comment off Linear. The job must no-op instead.
      live = @creative.comments.new(content: "back in main", user: @user)
      live.skip_linear_sync = true # suppress the observer during setup only
      live.save!
      # The flag is a plain attr_accessor, not DB-backed — reload won't clear it,
      # so reset it explicitly to reflect the real (syncable) row state.
      live.skip_linear_sync = nil
      assert CollavreLinear::CommentSyncability.syncable?(live),
        "guard: the comment must be syncable again for this scenario"

      link = CollavreLinear::CommentLink.create!(
        comment_id:        live.id,
        linear_comment_id: "lin-del-live",
        issue_link:        @issue_link
      )

      CollavreLinear::Client.stub(:new, @fake_client) do
        CollavreLinear::OutboundCommentDeleteJob.perform_now(link.id)
      end

      assert_equal 0, @fake_client.delete_calls.size,
        "a re-visible comment's mirror must not be deleted"
      assert CollavreLinear::CommentLink.find_by(id: link.id),
        "the CommentLink must survive so the comment stays mirrored"
    end

    test "no-op when the CommentLink is already gone (idempotent re-run)" do
      @link.destroy

      assert_nothing_raised do
        CollavreLinear::Client.stub(:new, @fake_client) do
          CollavreLinear::OutboundCommentDeleteJob.perform_now(@link.id)
        end
      end
      assert_equal 0, @fake_client.delete_calls.size
    end
  end
end
