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
        args: [child.id]
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
        args: [child.id]
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
    # Destroy path
    # -------------------------------------------------------------------------

    test "destroying a linked Creative enqueues OutboundSyncJob" do
      child = Collavre::Creative.create!(
        description: "<p>Child</p>",
        user: @user,
        parent: @root_creative
      )

      assert_enqueued_jobs 1, only: CollavreLinear::OutboundSyncJob do
        child.destroy!
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
        args: [wanderer.id]
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
