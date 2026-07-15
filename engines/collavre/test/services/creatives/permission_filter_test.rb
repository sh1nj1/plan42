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

    test "batch filter excludes a linked shell the viewer does not own, even when its origin is readable" do
      # @owner can read the origin (owns it), but @linked is @shared_user's
      # private shell row. FilterPipeline#resolve_ancestors pulls every
      # Creative.where(origin_id: ...) regardless of owner, so a batch can be
      # fed foreign shells. Origin readability alone must NOT surface another
      # user's shell placement — that would leak their tree structure.
      batch = Creatives::PermissionFilter.new(user: @owner)
        .readable_ids([ @linked.id ])

      assert_equal [], batch,
        "the origin owner must not receive another user's shell just because the origin is readable"
    end

    test "batch filter still returns a linked shell to the user who owns it" do
      # Guards the anti-leak gate against over-restriction: the shell's own
      # owner still reads it (origin readable + shell owned).
      batch = Creatives::PermissionFilter.new(user: @shared_user)
        .readable_ids([ @linked.id ])

      assert_equal [ @linked.id ], batch
    end

    test "batch filter normalizes string ids so param-sourced ids resolve identically to integers" do
      # ids reaching readable_ids from request params arrive as strings. Without
      # coercion the string key misses the integer-keyed origin lookup and the
      # integer-keyed readable Set, so a readable linked creative would silently
      # disappear (fail-closed). Coercion keeps string and integer inputs equal.
      string_batch = Creatives::PermissionFilter.new(user: @shared_user)
        .readable_ids([ @linked.id.to_s ])
      integer_batch = Creatives::PermissionFilter.new(user: @shared_user)
        .readable_ids([ @linked.id ])

      assert_equal [ @linked.id ], string_batch,
        "a string id must resolve the linked creative to its origin exactly like the integer id"
      assert_equal integer_batch, string_batch
    end

    test "batch filter excludes a foreign shell but keeps the viewer's own rows in the same batch" do
      owner_direct = perform_enqueued_jobs do
        Creative.create!(user: @owner, description: "Owner direct child", parent: @origin)
      end

      batch = Creatives::PermissionFilter.new(user: @owner)
        .readable_ids([ @linked.id, owner_direct.id, @origin.id ])

      assert_equal [ owner_direct.id, @origin.id ].sort, batch.sort,
        "foreign shell dropped; owned/readable rows in the same batch preserved"
    end

    # --- PR 1: min_permission: threshold ---------------------------------
    # readable_ids gains a min_permission: keyword so the write-posture bypass
    # sites (attachments_controller) and children_with_permission(min) can share
    # the one batch filter instead of re-deriving the rank comparison.

    test "readable_ids min_permission: defaults to :read (byte-identical to no arg)" do
      pf = Creatives::PermissionFilter.new(user: @shared_user)
      assert_equal pf.readable_ids([ @origin.id ]),
        pf.readable_ids([ @origin.id ], min_permission: :read)
    end

    test "readable_ids with min_permission: :write excludes a read-only share" do
      pf = Creatives::PermissionFilter.new(user: @shared_user)
      assert_equal [ @origin.id ], pf.readable_ids([ @origin.id ], min_permission: :read),
        "@shared_user has a read share on the origin"
      assert_equal [], pf.readable_ids([ @origin.id ], min_permission: :write),
        "a read share must not satisfy the :write threshold"
    end

    test "readable_ids with min_permission: :write includes a write share" do
      perform_enqueued_jobs do
        CreativeShare.create!(creative: @origin, user: @stranger, permission: "write")
      end
      batch = Creatives::PermissionFilter.new(user: @stranger)
        .readable_ids([ @origin.id ], min_permission: :write)
      assert_equal [ @origin.id ], batch
    end

    test "readable_ids min_permission: :write keeps the owner (admin) readable" do
      batch = Creatives::PermissionFilter.new(user: @owner)
        .readable_ids([ @origin.id ], min_permission: :write)
      assert_equal [ @origin.id ], batch,
        "the owner has admin and satisfies any threshold"
    end

    test "readable_ids min_permission applies to public shares too" do
      perform_enqueued_jobs do
        CreativeShare.create!(creative: @origin, user: nil, permission: "read")
      end
      pf = Creatives::PermissionFilter.new(user: @stranger)
      assert_equal [ @origin.id ], pf.readable_ids([ @origin.id ], min_permission: :read),
        "public read share grants read to a stranger"
      assert_equal [], pf.readable_ids([ @origin.id ], min_permission: :write),
        "public read share must not satisfy :write"
    end

    # --- PR 1: ranks_for -------------------------------------------------
    # ranks_for returns { id => effective_rank } mirroring single-item
    # PermissionChecker (owner wins -> user entry incl. no_access -> public ->
    # absent). It intentionally does NOT apply readable_ids' shell-ownership
    # anti-leak gate: it is for tree_builder/slide_viewable which operate on
    # creatives already in the viewer's own tree, matching PermissionChecker.

    test "ranks_for returns admin rank for an owned creative" do
      ranks = Creatives::PermissionFilter.new(user: @owner).ranks_for([ @origin.id ])
      assert_equal CreativeShare.permissions[:admin], ranks[@origin.id]
    end

    test "ranks_for returns the user's own share rank" do
      ranks = Creatives::PermissionFilter.new(user: @shared_user).ranks_for([ @origin.id ])
      assert_equal CreativeShare.permissions[:read], ranks[@origin.id]
    end

    test "ranks_for resolves a linked shell to its origin's rank, keyed by the input id" do
      ranks = Creatives::PermissionFilter.new(user: @shared_user).ranks_for([ @linked.id ])
      assert_equal CreativeShare.permissions[:read], ranks[@linked.id],
        "the shell borrows its origin's permission and is keyed by the shell (input) id"
    end

    test "ranks_for omits an id the user cannot access at all" do
      ranks = Creatives::PermissionFilter.new(user: @stranger).ranks_for([ @origin.id ])
      refute ranks.key?(@origin.id),
        "no owner, no user entry, no public share => absent (distinct from rank 0)"
    end

    test "ranks_for returns no_access rank (0) when a user deny beats a public share" do
      perform_enqueued_jobs do
        CreativeShare.create!(creative: @origin, user: nil, permission: "read")
        CreativeShare.create!(creative: @origin, user: @stranger, permission: "no_access")
      end
      ranks = Creatives::PermissionFilter.new(user: @stranger).ranks_for([ @origin.id ])
      assert_equal CreativeShare.permissions[:no_access], ranks[@origin.id],
        "the user's no_access entry must win over the public read share"
    end

    test "ranks_for falls back to the public share rank when there is no user entry" do
      perform_enqueued_jobs do
        CreativeShare.create!(creative: @origin, user: nil, permission: "feedback")
      end
      ranks = Creatives::PermissionFilter.new(user: @stranger).ranks_for([ @origin.id ])
      assert_equal CreativeShare.permissions[:feedback], ranks[@origin.id]
    end

    test "ranks_for agrees with PermissionChecker's allowed? across thresholds" do
      # Parity guard: for every rank ranks_for reports, allowed?(threshold) must
      # match rank >= threshold, so converging sites onto ranks_for cannot drift.
      pf = Creatives::PermissionFilter.new(user: @shared_user)
      rank = pf.ranks_for([ @origin.id ])[@origin.id]
      checker = Creatives::PermissionChecker.new(@origin, @shared_user)
      [ :read, :feedback, :write, :admin ].each do |threshold|
        expected = rank >= CreativeShare.permissions[threshold.to_s]
        assert_equal expected, checker.allowed?(threshold),
          "ranks_for rank #{rank} vs allowed?(#{threshold}) must agree"
      end
    end

    # --- PR 1: anonymous (user: nil) path --------------------------------
    # An unauthenticated viewer has no user cache entries, so both entry points
    # resolve purely against public shares. These pin that branch (no user
    # entries queried; public shares still honor the min_permission threshold).

    test "readable_ids for an anonymous user resolves against public shares only, honoring the threshold" do
      perform_enqueued_jobs do
        CreativeShare.create!(creative: @origin, user: nil, permission: "read")
      end
      pf = Creatives::PermissionFilter.new(user: nil)
      assert_equal [ @origin.id ], pf.readable_ids([ @origin.id ], min_permission: :read),
        "public read share grants read to an anonymous viewer"
      assert_equal [], pf.readable_ids([ @origin.id ], min_permission: :write),
        "public read share must not satisfy :write for an anonymous viewer"
    end

    test "readable_ids for an anonymous user excludes a creative with no public share" do
      assert_equal [], Creatives::PermissionFilter.new(user: nil).readable_ids([ @origin.id ]),
        "with no public share, an anonymous viewer reads nothing"
    end

    test "ranks_for for an anonymous user falls back to the public share rank" do
      perform_enqueued_jobs do
        CreativeShare.create!(creative: @origin, user: nil, permission: "feedback")
      end
      ranks = Creatives::PermissionFilter.new(user: nil).ranks_for([ @origin.id ])
      assert_equal CreativeShare.permissions[:feedback], ranks[@origin.id],
        "an anonymous viewer's rank comes solely from the public share"
    end

    test "ranks_for for an anonymous user omits a creative with no public share" do
      ranks = Creatives::PermissionFilter.new(user: nil).ranks_for([ @origin.id ])
      refute ranks.key?(@origin.id),
        "no public share => absent for an anonymous viewer (not the owner, no user entry)"
    end
  end
end
