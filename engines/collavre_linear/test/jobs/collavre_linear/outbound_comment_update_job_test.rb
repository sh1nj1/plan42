# frozen_string_literal: true

require "test_helper"

module CollavreLinear
  class OutboundCommentUpdateJobTest < ActiveSupport::TestCase
    # Plain stub conforming to Client's public comment interface — no network.
    class FakeClient
      attr_reader :update_calls

      def initialize(response: { id: "lin-cmt-1", updatedAt: "2026-07-01T00:00:00Z" })
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
      link = CollavreLinear::CommentLink.create!(
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
      # The edit's Linear updatedAt advances the synced baseline so the echo of
      # this edit is recognised as ours by the inbound applier.
      assert_equal Time.utc(2026, 7, 1), link.reload.remote_updated_at
    end

    test "pushes the freshest committed body, not the value at enqueue time" do
      CollavreLinear::CommentLink.create!(
        comment_id:        @comment.id,
        linear_comment_id: "lin-cmt-1",
        issue_link:        @issue_link
      )
      # A later edit landed before this job runs. The job reloads under the lock,
      # so it pushes the current body — the guard against an out-of-order pair of
      # edit jobs overwriting Linear back to a stale body.
      @comment.update_columns(content: "edited body")

      CollavreLinear::Client.stub(:new, @fake_client) do
        CollavreLinear::OutboundCommentUpdateJob.perform_now(@comment.id)
      end

      assert_equal "\\[Comment Update Test\\]: edited body",
        @fake_client.update_calls.first[:body]
    end

    test "no-op when the linked issue is frozen at :conflict, preserving the mirror" do
      link = CollavreLinear::CommentLink.create!(
        comment_id:        @comment.id,
        linear_comment_id: "lin-cmt-1",
        issue_link:        @issue_link
      )
      # The issue froze at :conflict after this edit was enqueued: pushing now
      # would update the comment on the stale issue in the OLD project. The write
      # must freeze until an explicit resync. Unlike a visibility change, the
      # mirror is KEPT (no delete) — only the outbound edit is withheld.
      @issue_link.update!(sync_state: :conflict)
      @comment.update_columns(content: "edited while conflicted")

      CollavreLinear::Client.stub(:new, @fake_client) do
        CollavreLinear::OutboundCommentUpdateJob.perform_now(@comment.id)
      end

      assert_equal 0, @fake_client.update_calls.size,
        "must not push an edit to a conflict-frozen (stale-project) issue"
      assert_not_nil CollavreLinear::CommentLink.find_by(id: link.id),
        "the comment mirror must be preserved through the conflict freeze"
    end

    test "no-op when the comment was made private after the update was enqueued" do
      CollavreLinear::CommentLink.create!(
        comment_id:        @comment.id,
        linear_comment_id: "lin-cmt-1",
        issue_link:        @issue_link
      )
      # Visibility changed between enqueue and run: pushing the now-hidden body to
      # Linear would leak it. The delete job (enqueued by the observer) owns
      # teardown; this update must no-op.
      @comment.update_columns(private: true)

      CollavreLinear::Client.stub(:new, @fake_client) do
        CollavreLinear::OutboundCommentUpdateJob.perform_now(@comment.id)
      end

      assert_equal 0, @fake_client.update_calls.size,
        "must not push a comment that is no longer public/Main"
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
