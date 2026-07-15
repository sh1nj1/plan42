require "test_helper"

module Collavre
  # Covers the declarative permission-cache invalidation registry on Creative
  # and the origin_id immutability guard.
  class CreativePermissionInvalidationTest < ActiveSupport::TestCase
    include ActiveJob::TestHelper

    setup do
      @owner = users(:one)
      @other = users(:two)
      perform_enqueued_jobs do
        @root = Creative.create!(user: @owner, description: "Root", progress: 0.0)
        @other_parent = Creative.create!(user: @owner, description: "Other parent", progress: 0.0)
        @creative = Creative.create!(user: @owner, description: "Child", progress: 0.0, parent: @root)
      end
    end

    test "registry declares the permission-invalidating attributes" do
      assert_equal :rebuild, Creative::Permissible::PERMISSION_INVALIDATING_ATTRIBUTES["parent_id"]
      assert_equal :rebuild_owner, Creative::Permissible::PERMISSION_INVALIDATING_ATTRIBUTES["user_id"]
      assert_equal :rebuild, Creative::Permissible::PERMISSION_INVALIDATING_ATTRIBUTES["origin_id"]
    end

    test "changing parent_id enqueues a subtree rebuild" do
      calls = capture_permission_cache_jobs do
        @creative.update!(parent: @other_parent)
      end
      assert_includes calls, [ :rebuild_for_creative, { creative_id: @creative.id } ]
    end

    test "changing user_id enqueues an owner-cache move" do
      calls = capture_permission_cache_jobs do
        @creative.update!(user: @other)
      end
      assert_includes calls,
        [ :update_owner, { creative_id: @creative.id, old_user_id: @owner.id, new_user_id: @other.id } ]
    end

    test "an untracked attribute change enqueues no rebuild" do
      calls = capture_permission_cache_jobs do
        @creative.update!(description: "Renamed")
      end
      rebuild_ops = calls.map(&:first)
      refute_includes rebuild_ops, :rebuild_for_creative
      refute_includes rebuild_ops, :update_owner
    end

    # --- Multi-save clobber (mirrors CreativeShare #1393 / 00502d7d) ---
    # after_commit sees only the LAST save's saved_changes. If a permission
    # attribute changes in one save and a later same-transaction save touches
    # only untracked columns, the permission change is clobbered out of
    # saved_changes and a saved_changes-gated dispatcher silently skips the
    # rebuild, leaving the permission cache stale (fail-open).

    # Reachable today: reorder_multiple_as_child/sibling wrap update!(parent:)
    # and resequence!'s update_column(:sequence) in one Creative.transaction.
    # update_column wipes saved_changes, so at the deferred after_commit the
    # parent_id change is gone and the subtree rebuild is skipped -> the moved
    # subtree keeps its old inherited shares (fail-open).
    test "re-parenting via reorder_multiple rebuilds the moved subtree cache" do
      new_parent = Creative.create!(user: @owner, description: "New parent", progress: 0.0)
      # Give new_parent an existing child so the dragged creative's sequence
      # actually changes during resequence! (0 -> 1); an unchanged sequence is a
      # no-op that would not exercise the update_column clobber.
      perform_enqueued_jobs do
        Creative.create!(user: @owner, description: "Existing", progress: 0.0, parent: new_parent, sequence: 0)
      end
      reorderer = Creatives::Reorderer.new(user: @owner)
      calls = capture_permission_cache_jobs do
        reorderer.reorder_multiple(
          dragged_ids: [ @creative.id ],
          target_id: new_parent.id,
          direction: "child"
        )
      end
      assert_includes calls, [ :rebuild_for_creative, { creative_id: @creative.id } ],
        "re-parenting via reorder_multiple must rebuild the moved subtree's permission cache"
    end

    test "a parent_id change survives a later same-transaction untracked save" do
      calls = capture_permission_cache_jobs do
        ActiveRecord::Base.transaction do
          @creative.update!(parent: @other_parent) # tracked -> :rebuild
          @creative.update!(description: "Renamed") # untracked; clobbers saved_changes
        end
      end
      assert_includes calls, [ :rebuild_for_creative, { creative_id: @creative.id } ],
        "the parent_id change must survive a later same-transaction untracked save"
    end

    test "a user_id change survives a later same-transaction untracked save with correct old/new" do
      calls = capture_permission_cache_jobs do
        ActiveRecord::Base.transaction do
          @creative.update!(user: @other) # tracked -> :rebuild_owner
          @creative.update!(description: "Renamed") # untracked; clobbers saved_changes
        end
      end
      assert_includes calls,
        [ :update_owner, { creative_id: @creative.id, old_user_id: @owner.id, new_user_id: @other.id } ],
        "the owner change must survive a later same-transaction untracked save with the correct old/new pair"
    end

    test "origin_id is immutable once persisted" do
      origin_a = @root
      origin_b = @other_parent
      linked = nil
      perform_enqueued_jobs do
        linked = Creative.create!(origin: origin_a, user: @other, parent_id: nil)
      end

      # attr_readonly promotes the "origin_id is immutable" invariant to a
      # model-level guard that rejects any repoint of a persisted link.
      assert_raises(ActiveRecord::ReadonlyAttributeError) do
        linked.update!(origin_id: origin_b.id)
      end

      linked.reload
      assert_equal origin_a.id, linked.origin_id,
        "origin_id must not change on a persisted record (attr_readonly guard)"
    end

    private

    def capture_permission_cache_jobs(&block)
      calls = []
      recorder = lambda do |operation, **kwargs|
        calls << [ operation, kwargs ]
        nil
      end
      PermissionCacheJob.stub(:perform_later, recorder, &block)
      calls
    end
  end
end
