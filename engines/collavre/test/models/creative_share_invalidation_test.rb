require "test_helper"

module Collavre
  # Covers the declarative permission-cache invalidation registry on
  # CreativeShare — the second write entry point, unified to mirror
  # Creative::Permissible so that a new share-mutation path can never
  # silently skip a required cache rebuild.
  #
  # The end-state semantics (which cache rows exist after each mutation) are
  # already pinned by CreativePermissionCacheTest. This file pins the dispatch
  # *mechanism*: the declarative map, which job each change enqueues, and that
  # every update re-propagates unconditionally (fail-closed) so a multi-save
  # transaction can't silently drop a permission change.
  class CreativeShareInvalidationTest < ActiveSupport::TestCase
    include ActiveJob::TestHelper

    setup do
      @owner = users(:one)
      @user1 = users(:two)
      @user2 = users(:three)
      Current.session = OpenStruct.new(user: @owner)
      perform_enqueued_jobs do
        @root = Creative.create!(user: @owner, description: "Root", progress: 0.0)
        @other_root = Creative.create!(user: @owner, description: "Other root", progress: 0.0)
      end
    end

    teardown { Current.reset }

    test "registry declares the share-invalidating attributes" do
      map = CreativeShare::PERMISSION_INVALIDATING_ATTRIBUTES
      assert_equal :relocate, map["creative_id"]
      assert_equal :reassign, map["user_id"]
      assert_equal :repropagate, map["permission"]
    end

    test "creating a share enqueues a single propagate_share" do
      share = nil
      calls = capture_permission_cache_jobs do
        share = CreativeShare.create!(creative: @root, user: @user1, permission: :read)
      end
      # Filter to this share's dispatch; creating the recipient's inbox creative
      # (via notify_recipient) legitimately fires owner-cache jobs for a
      # different creative, which are not part of the share dispatcher.
      share_calls = calls.select { |_op, kw| kw[:creative_share_id] == share.id }
      assert_equal [ [ :propagate_share, { creative_share_id: share.id } ] ], share_calls
    end

    test "changing only permission re-propagates the share" do
      share = create_share(@root, @user1, :read)
      calls = capture_permission_cache_jobs do
        share.update!(permission: :write)
      end
      assert_equal [ [ :propagate_share, { creative_share_id: share.id } ] ], calls
    end

    test "changing creative_id relocates: rebuild vacated old subtree then propagate" do
      share = create_share(@root, @user1, :read)
      old_creative_id = @root.id
      calls = capture_permission_cache_jobs do
        share.update!(creative: @other_root)
      end
      # The stale-row purge is now enqueued (async), mirroring the destroy path,
      # rather than deleted synchronously inside after_commit.
      assert_includes calls, [ :purge_share_cache, { creative_share_id: share.id } ]
      assert_includes calls,
        [ :rebuild_user_cache_for_subtree, { creative_id: old_creative_id, user_id: @user1.id } ]
      assert_includes calls, [ :propagate_share, { creative_share_id: share.id } ]
    end

    test "changing user_id reassigns: rebuild old user's subtree then propagate" do
      share = create_share(@root, @user1, :read)
      calls = capture_permission_cache_jobs do
        share.update!(user: @user2)
      end
      assert_includes calls, [ :purge_share_cache, { creative_share_id: share.id } ]
      assert_includes calls,
        [ :rebuild_user_cache_for_subtree, { creative_id: @root.id, user_id: @user1.id } ]
      assert_includes calls, [ :propagate_share, { creative_share_id: share.id } ]
    end

    test "an untracked-only update still re-propagates the share (fail-closed)" do
      share = create_share(@root, @user1, :read)
      calls = capture_permission_cache_jobs do
        share.update!(shared_by_id: @user2.id)
      end
      # The prior propagate_cache re-propagated on EVERY update. Preserve that
      # fail-closed refresh: gating propagate on saved_changes would drop a
      # permission change that a later same-transaction save clobbers out of the
      # final saved_changes (untracked columns only carry the base propagate).
      assert_equal [ [ :propagate_share, { creative_share_id: share.id } ] ], calls,
        "every update must re-propagate, even when only an untracked column changed"
    end

    test "a permission change is not lost when a later same-transaction save clobbers saved_changes" do
      share = create_share(@root, @user1, :read)
      calls = capture_permission_cache_jobs do
        ActiveRecord::Base.transaction do
          share.update!(permission: :write)      # tracked change
          share.update!(shared_by_id: @user2.id) # untracked; clobbers saved_changes at commit
        end
      end
      # at after_commit, saved_changes reflects only the final (untracked) save,
      # so an operations-gated dispatcher would skip the write grant entirely.
      assert_includes calls, [ :propagate_share, { creative_share_id: share.id } ],
        "the permission change must survive a later same-transaction untracked save"
    end

    test "relocate purges stale cache rows via the enqueued job, not synchronously at commit" do
      share = create_share(@root, @user1, :read)
      stale_rows = -> { CreativeSharesCache.where(source_share_id: share.id, creative_id: @root.id) }
      assert stale_rows.call.exists?,
        "precondition: propagate_share populated the share's cache row at the old creative"

      # Under a deferred (test) adapter the relocate enqueues purge_share_cache
      # but does NOT run it — proving the stale-row delete is async now, not a
      # synchronous delete_all inside after_commit. The revoke of the vacated
      # access is therefore prolonged by the queue latency, which is the accepted
      # trade-off (it only extends an existing grant, never creates a new one).
      # The suite's default adapter is :inline, so switch to :test to observe the
      # commit boundary independently of the job execution.
      with_deferred_jobs do
        share.update!(creative: @other_root)
        assert_enqueued_with(job: PermissionCacheJob,
          args: [ :purge_share_cache, { creative_share_id: share.id } ])
        assert stale_rows.call.exists?,
          "stale rows must survive the commit; the purge is deferred to the job"
        perform_enqueued_jobs
      end

      assert_not stale_rows.call.exists?,
        "the enqueued purge job deletes the stale rows the share vacated"
    end

    test "destroying a share enqueues remove_share" do
      share = create_share(@root, @user1, :read)
      calls = capture_permission_cache_jobs do
        share.destroy!
      end
      assert_equal [ [ :remove_share,
        { creative_share_id: share.id, creative_id: @root.id, user_id: @user1.id } ] ], calls
    end

    private

    def create_share(creative, user, permission)
      share = nil
      perform_enqueued_jobs do
        share = CreativeShare.create!(creative: creative, user: user, permission: permission)
      end
      share
    end

    # The suite runs on the :inline adapter (jobs execute at enqueue time), which
    # can't distinguish "enqueued" from "performed". Swap to the :test adapter so
    # a block can inspect the commit boundary before the jobs run.
    def with_deferred_jobs
      old_adapter = ActiveJob::Base.queue_adapter
      ActiveJob::Base.queue_adapter = :test
      yield
    ensure
      ActiveJob::Base.queue_adapter = old_adapter
    end

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
