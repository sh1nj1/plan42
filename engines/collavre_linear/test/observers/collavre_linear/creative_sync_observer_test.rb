# frozen_string_literal: true

require "test_helper"

module CollavreLinear
  class CreativeSyncObserverTest < ActiveSupport::TestCase
    include ActiveJob::TestHelper

    def setup
      @original_adapter = ActiveJob::Base.queue_adapter
      ActiveJob::Base.queue_adapter = :test

      @user = Collavre.user_class.create!(
        email: "observer-test-#{SecureRandom.hex(4)}@example.com",
        name: "Observer Test",
        password: TEST_PASSWORD,
        password_confirmation: TEST_PASSWORD,
        timezone: "UTC"
      )

      @account = CollavreLinear::Account.create!(
        user: @user,
        linear_uid: "uid-obs-#{SecureRandom.hex(4)}",
        access_token: "tok-obs"
      )

      # Root creative holds the ProjectLink (i.e. the linked subtree root).
      @root_creative = Collavre::Creative.create!(
        description: "<p>Root</p>",
        user: @user
      )

      @project_link = CollavreLinear::ProjectLink.create!(
        creative: @root_creative,
        account:  @account,
        linear_project_id: "proj-obs",
        team_id:           "team-obs"
      )
    end

    def teardown
      ActiveJob::Base.queue_adapter = @original_adapter
    end

    # -------------------------------------------------------------------------
    # Step 1 — linked subtree triggers exactly one OutboundSyncJob
    # -------------------------------------------------------------------------

    test "creating a Creative inside a linked subtree enqueues OutboundSyncJob once" do
      child = nil
      assert_enqueued_jobs 1, only: CollavreLinear::OutboundSyncJob do
        child = Collavre::Creative.create!(
          description: "<p>Child</p>",
          user: @user,
          parent: @root_creative
        )
      end

      assert_enqueued_with(
        job: CollavreLinear::OutboundSyncJob,
        args: [ child.id ]
      )
    end

    test "updating a Creative inside a linked subtree enqueues OutboundSyncJob once" do
      child = Collavre::Creative.create!(
        description: "<p>Child</p>",
        user: @user,
        parent: @root_creative
      )

      assert_enqueued_jobs 1, only: CollavreLinear::OutboundSyncJob do
        child.update!(description: "<p>Child edited</p>")
      end

      assert_enqueued_with(
        job: CollavreLinear::OutboundSyncJob,
        args: [ child.id ]
      )
    end

    # -------------------------------------------------------------------------
    # Unlinked subtree — nothing enqueued
    # -------------------------------------------------------------------------

    test "updating an unlinked Creative enqueues nothing" do
      orphan = Collavre::Creative.create!(description: "<p>Orphan</p>", user: @user)

      assert_no_enqueued_jobs only: CollavreLinear::OutboundSyncJob do
        orphan.update!(description: "<p>Orphan edited</p>")
      end
    end

    # -------------------------------------------------------------------------
    # Fix 1 — mark IssueLink dirty on update when link already exists
    # -------------------------------------------------------------------------

    test "updating a linked creative that already has an IssueLink marks it dirty and still enqueues" do
      child = Collavre::Creative.create!(
        description: "<p>Child</p>",
        user: @user,
        parent: @root_creative
      )

      # Create a pre-existing IssueLink (simulates a creative already synced to Linear).
      issue_link = CollavreLinear::IssueLink.create!(
        creative:        child,
        project_link:    @project_link,
        linear_issue_id: "iss-pre-existing-#{SecureRandom.hex(4)}",
        content_hash:    "abc123",
        sync_state:      :synced
      )

      assert_equal "synced", issue_link.sync_state

      assert_enqueued_jobs 1, only: CollavreLinear::OutboundSyncJob do
        child.update!(description: "<p>Child edited</p>")
      end

      assert_equal "dirty", issue_link.reload.sync_state,
        "IssueLink must be marked dirty before OutboundSyncJob is enqueued"
    end

    # -------------------------------------------------------------------------
    # Destroy path
    # -------------------------------------------------------------------------

    test "destroying a linked Creative with an IssueLink enqueues OutboundArchiveJob with linear_issue_id and account_id" do
      child = Collavre::Creative.create!(
        description: "<p>Child</p>",
        user: @user,
        parent: @root_creative
      )

      issue_link = CollavreLinear::IssueLink.create!(
        creative:        child,
        project_link:    @project_link,
        linear_issue_id: "iss-archive-#{SecureRandom.hex(4)}",
        content_hash:    "abc",
        sync_state:      :synced
      )

      expected_issue_id  = issue_link.linear_issue_id
      expected_account_id = @account.id

      # NOTE: the archive enqueue happens in an `after_commit` on destroy. Under
      # parallel execution a strict count-in-block (`assert_enqueued_jobs 1 do
      # child.destroy! end`) is timing/contention sensitive, so we destroy first
      # and then assert against the *accumulated* queue. `assert_enqueued_with`
      # scans every job enqueued during the test — it proves the archive job was
      # enqueued with the exact captured ids regardless of when the commit
      # callback fired — and an explicit count assertion proves it fired exactly
      # once (no duplicates, and the two negative tests below still guarantee it
      # does not fire when there is no IssueLink / no link).
      child.destroy!

      assert_enqueued_with(
        job:  CollavreLinear::OutboundArchiveJob,
        args: [ expected_issue_id, expected_account_id ]
      )

      archive_jobs = enqueued_jobs.select do |job|
        job[:job] == CollavreLinear::OutboundArchiveJob
      end
      assert_equal 1, archive_jobs.size,
        "expected exactly one OutboundArchiveJob to be enqueued on destroy"
    end

    test "destroying a linked Creative with NO IssueLink enqueues nothing" do
      child = Collavre::Creative.create!(
        description: "<p>No link</p>",
        user: @user,
        parent: @root_creative
      )

      assert_no_enqueued_jobs only: CollavreLinear::OutboundArchiveJob do
        assert_no_enqueued_jobs only: CollavreLinear::OutboundSyncJob do
          child.destroy!
        end
      end
    end

    test "destroying an unlinked Creative enqueues nothing" do
      orphan = Collavre::Creative.create!(description: "<p>Orphan</p>", user: @user)

      assert_no_enqueued_jobs only: CollavreLinear::OutboundArchiveJob do
        assert_no_enqueued_jobs only: CollavreLinear::OutboundSyncJob do
          orphan.destroy!
        end
      end
    end

    # -------------------------------------------------------------------------
    # Move (parent_id change) into a linked subtree
    # -------------------------------------------------------------------------

    test "moving a Creative into a linked subtree enqueues OutboundSyncJob" do
      # Start outside any linked subtree.
      wanderer = Collavre::Creative.create!(description: "<p>Wanderer</p>", user: @user)

      assert_enqueued_jobs 1, only: CollavreLinear::OutboundSyncJob do
        wanderer.update!(parent: @root_creative)
      end

      assert_enqueued_with(
        job: CollavreLinear::OutboundSyncJob,
        args: [ wanderer.id ]
      )
    end

    # -------------------------------------------------------------------------
    # Step 4 — inbound suppression via skip_linear_sync
    # -------------------------------------------------------------------------

    test "a Creative mutated with skip_linear_sync = true enqueues nothing" do
      child = Collavre::Creative.create!(
        description: "<p>Child</p>",
        user: @user,
        parent: @root_creative
      )

      assert_no_enqueued_jobs only: CollavreLinear::OutboundSyncJob do
        child.skip_linear_sync = true
        child.update!(description: "<p>Applied by inbound</p>")
      end
    end
  end
end
