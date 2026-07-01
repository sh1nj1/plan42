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
  end
end
