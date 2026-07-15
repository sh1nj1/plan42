require "test_helper"

# Characterization tests (rot-remediation ②, PR 0) — NO production change.
#
# Five read sites re-implement the permission deny-invariant by querying
# CreativeSharesCache directly instead of going through the canonical
# PermissionChecker / PermissionFilter:
#
#   1. Creative#children_with_permission
#   2. Concerns::SlideViewable#accessible_child_ids
#   3. Creatives::TreeBuilder#preload_permissions
#   4. AttachmentsController#editable_creative_reference?
#   5. Tools::CreativeRetrievalService#accessible_creative_ids
#
# Convergence PRs 2–5 will rewrite each site as a thin PermissionFilter caller.
# These tests pin the CURRENT observable behavior of every site — including the
# deliberate posture divergence of site 5 — so convergence can prove it either
# preserved behavior or changed it on purpose. Assertions capture what the code
# actually does today, not what it ideally should.
class PermissionReadCharacterizationTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  # Build one matrix of children under a common root, covering every posture the
  # deny-invariant distinguishes: owner-wins, user read/write share, a
  # user-specific no_access deny layered over a public read (deny must win),
  # public read only, and no share at all.
  setup do
    @owner = users(:one)
    @user = users(:two)
    @stranger = users(:three)

    perform_enqueued_jobs do
      @root = Creative.create!(user: @owner, description: "Root", progress: 0.0)

      @owned_by_user = Creative.create!(user: @user, parent: @root, description: "Owned by user")
      @user_read = Creative.create!(user: @owner, parent: @root, description: "User read")
      @user_write = Creative.create!(user: @owner, parent: @root, description: "User write")
      @deny_over_public = Creative.create!(user: @owner, parent: @root, description: "Deny over public")
      @public_read = Creative.create!(user: @owner, parent: @root, description: "Public read")
      @none = Creative.create!(user: @owner, parent: @root, description: "No share")

      CreativeShare.create!(creative: @user_read, user: @user, permission: "read")
      CreativeShare.create!(creative: @user_write, user: @user, permission: "write")
      # Public read granted, but the user is explicitly denied — deny must win.
      CreativeShare.create!(creative: @deny_over_public, user: nil, permission: "read")
      CreativeShare.create!(creative: @deny_over_public, user: @user, permission: "no_access")
      CreativeShare.create!(creative: @public_read, user: nil, permission: "read")
    end

    @children = [ @owned_by_user, @user_read, @user_write, @deny_over_public, @public_read, @none ]
    @child_ids = @children.map(&:id)
  end

  def ids(collection)
    collection.map { |c| c.respond_to?(:id) ? c.id : c }.sort
  end

  # ---------------------------------------------------------------------------
  # Site 1 — Creative#children_with_permission
  # ---------------------------------------------------------------------------

  test "children_with_permission(:read) grants owner/user-share/public, deny beats public" do
    result = @root.children_with_permission(@user, :read)
    assert_equal ids([ @owned_by_user, @user_read, @user_write, @public_read ]),
      ids(result),
      "read set: owned + user read/write + public; @deny_over_public excluded (user no_access beats public), @none excluded"
  end

  test "children_with_permission(:write) requires write rank, owner still wins" do
    result = @root.children_with_permission(@user, :write)
    assert_equal ids([ @owned_by_user, @user_write ]),
      ids(result),
      "write set: only owned (owner=full) + explicit user write; read-only and public-read drop out"
  end

  test "children_with_permission(:read) for a stranger sees public shares including the deny target" do
    result = @root.children_with_permission(@stranger, :read)
    assert_equal ids([ @public_read, @deny_over_public ]),
      ids(result),
      "the no_access deny is user-specific to @user, so a stranger still reads @deny_over_public via its public share"
  end

  # Linked-shell children: a shell (origin_id set) has no cache rows of its own,
  # so children_with_permission decides purely on shell ROW ownership + the
  # origin's readability. These pin the two edges the PermissionFilter anti-leak
  # gate treats differently from raw ownership, so PR 2 convergence must preserve
  # them: (a) a shell the viewer OWNS is listed even when its origin is NOT
  # readable to the viewer (stale link stays visible in one's own tree), and
  # (b) a foreign shell (owned by another user) is NOT listed even when its
  # origin is public-readable (no leak of another user's placement).
  test "children_with_permission lists an owned shell child whose origin is NOT readable" do
    perform_enqueued_jobs do
      hidden_origin = Creative.create!(user: @stranger, description: "Hidden origin", progress: 0.0)
      @owned_shell = Creative.create!(user: @user, parent: @root, origin: hidden_origin)
    end
    result = @root.children_with_permission(@user, :read)
    assert_includes ids(result), @owned_shell.id,
      "viewer owns the shell row, so it is listed even though its origin is not shared with them"
  end

  test "children_with_permission omits a foreign shell child even if its origin is public-readable" do
    perform_enqueued_jobs do
      shared_origin = Creative.create!(user: @stranger, description: "Public origin", progress: 0.0)
      CreativeShare.create!(creative: shared_origin, user: nil, permission: "read")
      @foreign_shell = Creative.create!(user: @stranger, parent: @root, origin: shared_origin)
    end
    result = @root.children_with_permission(@user, :read)
    refute_includes ids(result), @foreign_shell.id,
      "the shell row belongs to @stranger; @user must not see it despite the origin's public read"
  end

  # ---------------------------------------------------------------------------
  # Site 2 — Concerns::SlideViewable#accessible_child_ids (mirrors site 1)
  # ---------------------------------------------------------------------------

  test "accessible_child_ids matches children_with_permission(:read) for the user" do
    host = Class.new { include Collavre::Concerns::SlideViewable }.new
    result = host.send(:accessible_child_ids, @child_ids, @children, @user)
    assert_equal ids([ @owned_by_user, @user_read, @user_write, @public_read ]),
      result.to_a.sort,
      "site 2 is documented to mirror site 1's read posture exactly"
  end

  test "accessible_child_ids for a stranger includes public + deny target" do
    host = Class.new { include Collavre::Concerns::SlideViewable }.new
    result = host.send(:accessible_child_ids, @child_ids, @children, @stranger)
    assert_equal ids([ @public_read, @deny_over_public ]),
      result.to_a.sort
  end

  test "accessible_child_ids for anonymous (nil user) returns only public non-deny shares" do
    host = Class.new { include Collavre::Concerns::SlideViewable }.new
    result = host.send(:accessible_child_ids, @child_ids, @children, nil)
    assert_equal ids([ @public_read, @deny_over_public ]),
      result.to_a.sort,
      "anonymous sees every public read share; the no_access deny is user-scoped and does not apply to nil"
  end

  # ---------------------------------------------------------------------------
  # Site 3 — Creatives::TreeBuilder#preload_permissions
  # ---------------------------------------------------------------------------

  def build_tree_builder(user)
    Collavre::Creatives::TreeBuilder.new(
      user: user, params: {}, view_context: nil,
      expanded_state_map: {}, select_mode: false, max_level: 3
    )
  end

  test "preload_permissions ranks owner=admin, user shares by rank, deny=no_access, public read, none=nil" do
    builder = build_tree_builder(@user)
    builder.send(:preload_permissions, @children)
    ranks = builder.instance_variable_get(:@permission_rank)

    admin = CreativeShare.permissions[:admin]
    assert_equal admin, ranks[@owned_by_user.id], "owner resolves to OWNER_RANK (admin)"
    assert_equal CreativeShare.permissions[:read], ranks[@user_read.id]
    assert_equal CreativeShare.permissions[:write], ranks[@user_write.id]
    assert_equal CreativeShare.permissions[:no_access], ranks[@deny_over_public.id],
      "user no_access entry wins over the public read entry (rank 0 denies)"
    assert_equal CreativeShare.permissions[:read], ranks[@public_read.id]
    assert_nil ranks[@none.id], "absent everywhere resolves to nil rank (distinct from no_access=0)"
  end

  test "preload_permissions for a stranger sees public read for both public rows, nil elsewhere" do
    builder = build_tree_builder(@stranger)
    builder.send(:preload_permissions, @children)
    ranks = builder.instance_variable_get(:@permission_rank)

    read = CreativeShare.permissions[:read]
    assert_equal read, ranks[@public_read.id]
    assert_equal read, ranks[@deny_over_public.id], "stranger sees the public read; the deny is user-scoped"
    assert_nil ranks[@owned_by_user.id]
    assert_nil ranks[@user_read.id]
    assert_nil ranks[@none.id]
  end

  # ---------------------------------------------------------------------------
  # Site 4 — AttachmentsController#editable_creative_reference? (write posture)
  # ---------------------------------------------------------------------------

  def reference_blob_in(creative)
    blob = ActiveStorage::Blob.create_and_upload!(
      io: StringIO.new("data"), filename: "a.txt", content_type: "text/plain"
    )
    creative.update!(description: "#{creative.description} ref:#{blob.signed_id}")
    blob
  end

  def editable_for?(blob, user)
    controller = Collavre::AttachmentsController.new
    Collavre::Current.user = user
    controller.send(:editable_creative_reference?, blob)
  ensure
    Collavre::Current.user = nil
  end

  test "editable_creative_reference? grants the owner write" do
    blob = reference_blob_in(@user_read)
    assert editable_for?(blob, @owner), "owner of the referencing creative always has write"
  end

  test "editable_creative_reference? grants a user with a write share" do
    blob = reference_blob_in(@user_write)
    assert editable_for?(blob, @user)
  end

  test "editable_creative_reference? denies a user with only a read share" do
    blob = reference_blob_in(@user_read)
    refute editable_for?(blob, @user), "read < write rank, so not editable"
  end

  test "editable_creative_reference? denies a user with a no_access deny over public" do
    blob = reference_blob_in(@deny_over_public)
    refute editable_for?(blob, @user), "user no_access entry beats the public share"
  end

  test "editable_creative_reference? denies a stranger on a public-read creative" do
    blob = reference_blob_in(@public_read)
    refute editable_for?(blob, @stranger), "public read grants read, not write"
  end

  # ---------------------------------------------------------------------------
  # Site 5 — Tools::CreativeRetrievalService#accessible_creative_ids
  # NOTE: this site diverges by design — it counts a user's OWN creatives plus
  # its user-specific (non-no_access) cache entries, and ignores public shares
  # entirely. PR 5 will converge it; this pins the pre-convergence posture.
  # ---------------------------------------------------------------------------

  def accessible_ids_for(user)
    service = Collavre::Tools::CreativeRetrievalService.new
    Collavre::Current.user = user
    service.send(:accessible_creative_ids)
  ensure
    Collavre::Current.user = nil
  end

  test "accessible_creative_ids returns own + user-specific non-deny shares, IGNORING public" do
    result = accessible_ids_for(@user)
    assert_equal ids([ @owned_by_user, @user_read, @user_write ]),
      result.sort,
      "site 5 posture: own creatives + user-specific shares (no_access excluded); @public_read and @deny_over_public NOT included"
  end

  test "accessible_creative_ids for a stranger ignores public shares entirely (empty)" do
    result = accessible_ids_for(@stranger)
    assert_equal [], result.sort,
      "stranger owns nothing and has no user-specific share; public reads are invisible to this site (documented divergence)"
  end
end
