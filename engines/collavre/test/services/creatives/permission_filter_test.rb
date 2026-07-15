require "test_helper"

module Creatives
  # Regression coverage for the read-path inconsistency: a single-item
  # PermissionChecker and the batch PermissionFilter must resolve a linked
  # creative to the SAME effective (origin) creative, so they can never return
  # different permission for the same user + linked creative.
  class PermissionFilterTest < ActiveSupport::TestCase
    include ActiveJob::TestHelper

    setup do
      @owner = users(:one)
      @shared_user = users(:two)
      @stranger = users(:three)

      perform_enqueued_jobs do
        @origin = Creative.create!(user: @owner, description: "Origin", progress: 0.0)
        # Share the origin with @shared_user so the cache holds an entry keyed
        # on the ORIGIN id (not the linked creative id).
        CreativeShare.create!(creative: @origin, user: @shared_user, permission: "read")
        # Linked creative for @shared_user points at the origin and has NO
        # cache entry of its own.
        @linked = Creative.create!(origin: @origin, user: @shared_user, parent_id: nil)
      end
    end

    test "linked creative yields identical permission via single check and batch filter" do
      single = Creatives::PermissionChecker.new(@linked, @shared_user).allowed?(:read)
      batch = Creatives::PermissionFilter.new(user: @shared_user)
        .readable_ids([ @linked.id ])

      assert single, "single check should grant read on the linked creative via its origin share"
      assert_equal [ @linked.id ], batch,
        "batch filter must resolve the linked creative to its origin and agree with the single check"
      assert_equal single, batch.include?(@linked.id),
        "single check and batch filter must never diverge for a linked creative"
    end

    test "batch filter denies a linked creative whose origin the user cannot read" do
      single = Creatives::PermissionChecker.new(@linked, @stranger).allowed?(:read)
      batch = Creatives::PermissionFilter.new(user: @stranger)
        .readable_ids([ @linked.id ])

      refute single, "stranger has no share on the origin"
      assert_equal [], batch, "batch filter must also deny the linked creative"
      assert_equal single, batch.include?(@linked.id)
    end

    test "batch filter still resolves plain (non-linked) creatives directly" do
      batch = Creatives::PermissionFilter.new(user: @shared_user)
        .readable_ids([ @origin.id ])
      assert_equal [ @origin.id ], batch
    end

    test "owner of the origin can read the linked creative via both paths" do
      single = Creatives::PermissionChecker.new(@linked, @owner).allowed?(:read)
      batch = Creatives::PermissionFilter.new(user: @owner)
        .readable_ids([ @linked.id ])

      assert single
      assert_equal [ @linked.id ], batch
    end
  end
end
