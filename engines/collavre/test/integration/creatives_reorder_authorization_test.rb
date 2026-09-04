require "test_helper"

# POST /creatives/reorder and /creatives/link_drop re-parent Creatives. Before
# this suite existed the endpoints looked up their operands with
# Creative.find_by(id:) and never consulted the acting user, so any signed-in
# account could re-parent an arbitrary Creative by id (IDOR).
#
# The matrix below pins the authorization contract: :write on every dragged
# Creative and on the container that receives it, :read on a link drop's source
# (a link never mutates it), 403 for a permission failure, 422 reserved for
# malformed or cyclic input, and no partial writes when one id in a batch fails.
class CreativesReorderAuthorizationTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

  setup do
    @owner = create_user("reorder-owner")
    @stranger = create_user("reorder-stranger")
    @collaborator = create_user("reorder-collaborator")

    perform_enqueued_jobs do
      @owner_root = Creative.create!(user: @owner, description: "Owner root", sequence: 0)
      @owner_a = Creative.create!(user: @owner, parent: @owner_root, description: "Owner A", sequence: 0)
      @owner_b = Creative.create!(user: @owner, parent: @owner_root, description: "Owner B", sequence: 1)

      @stranger_root = Creative.create!(user: @stranger, description: "Stranger root", sequence: 0)
      @stranger_a = Creative.create!(user: @stranger, parent: @stranger_root, description: "Stranger A", sequence: 0)

      @collaborator_root = Creative.create!(user: @collaborator, description: "Collaborator root", sequence: 0)
    end
  end

  # --- reorder: unauthorized -------------------------------------------------

  test "reorder is forbidden when the dragged creative is not writable" do
    sign_in_as(@stranger)

    post reorder_creatives_path, params: {
      dragged_id: @owner_a.id, target_id: @stranger_root.id, direction: "child"
    }, as: :json

    assert_response :forbidden
    assert_equal @owner_root.id, @owner_a.reload.parent_id
  end

  test "reorder is forbidden when the receiving container is not writable" do
    sign_in_as(@stranger)

    post reorder_creatives_path, params: {
      dragged_id: @stranger_a.id, target_id: @owner_a.id, direction: "child"
    }, as: :json

    assert_response :forbidden
    assert_equal @stranger_root.id, @stranger_a.reload.parent_id
  end

  # "up"/"down" land the dragged creative in the target's PARENT, so write on
  # the target alone must not be enough to inject into a container above it.
  test "reorder up is forbidden when the target's parent is not writable" do
    share!(@owner_a, @collaborator, :write)
    sign_in_as(@collaborator)

    post reorder_creatives_path, params: {
      dragged_id: @collaborator_root.id, target_id: @owner_a.id, direction: "up"
    }, as: :json

    assert_response :forbidden
    assert_nil @collaborator_root.reload.parent_id
  end

  test "reorder is forbidden with read-only access" do
    share!(@owner_root, @collaborator, :read)
    sign_in_as(@collaborator)

    post reorder_creatives_path, params: {
      dragged_id: @owner_b.id, target_id: @owner_a.id, direction: "up"
    }, as: :json

    assert_response :forbidden
    assert_equal [ @owner_a.id, @owner_b.id ], @owner_root.children.order(:sequence).pluck(:id)
  end

  test "reorder cannot move a link shell from another user's private placement" do
    share!(@owner_root, @collaborator, :write)
    foreign_shell = Creative.create!(
      user: @stranger,
      parent: @stranger_root,
      origin_id: @owner_a.id,
      sequence: 1
    )
    sign_in_as(@collaborator)

    post reorder_creatives_path, params: {
      dragged_id: foreign_shell.id, target_id: @collaborator_root.id, direction: "child"
    }, as: :json

    assert_response :forbidden
    assert_equal @stranger_root.id, foreign_shell.reload.parent_id
  end

  test "reorder cannot insert into another user's private link shell" do
    share!(@owner_root, @collaborator, :write)
    foreign_shell = Creative.create!(
      user: @stranger,
      parent: @stranger_root,
      origin_id: @owner_a.id,
      sequence: 1
    )
    sign_in_as(@collaborator)

    post reorder_creatives_path, params: {
      dragged_id: @collaborator_root.id, target_id: foreign_shell.id, direction: "child"
    }, as: :json

    assert_response :forbidden
    assert_nil @collaborator_root.reload.parent_id
  end

  # --- reorder: authorized ---------------------------------------------------

  test "owner can reorder their own creatives" do
    sign_in_as(@owner)

    post reorder_creatives_path, params: {
      dragged_id: @owner_b.id, target_id: @owner_a.id, direction: "up"
    }, as: :json

    assert_response :ok
    assert_equal [ @owner_b.id, @owner_a.id ], @owner_root.children.order(:sequence).pluck(:id)
  end

  test "a write-shared collaborator can reorder inside the shared subtree" do
    share!(@owner_root, @collaborator, :write)
    sign_in_as(@collaborator)

    post reorder_creatives_path, params: {
      dragged_id: @owner_b.id, target_id: @owner_a.id, direction: "up"
    }, as: :json

    assert_response :ok
    assert_equal [ @owner_b.id, @owner_a.id ], @owner_root.children.order(:sequence).pluck(:id)
  end

  # --- reorder_multiple ------------------------------------------------------

  test "multi-drag is rejected in full when one dragged creative is unauthorized" do
    sign_in_as(@stranger)

    post reorder_creatives_path, params: {
      dragged_ids: [ @stranger_a.id, @owner_a.id ],
      target_id: @stranger_root.id,
      direction: "child"
    }, as: :json

    assert_response :forbidden
    assert_equal @owner_root.id, @owner_a.reload.parent_id
    assert_equal @stranger_root.id, @stranger_a.reload.parent_id
  end

  test "multi-drag succeeds when every dragged creative is authorized" do
    sign_in_as(@owner)

    post reorder_creatives_path, params: {
      dragged_ids: [ @owner_b.id, @owner_a.id ],
      target_id: @collaborator_root.id,
      direction: "child"
    }, as: :json

    assert_response :forbidden, "the collaborator's root is not writable by the owner"

    post reorder_creatives_path, params: {
      dragged_ids: [ @owner_b.id, @owner_a.id ],
      target_id: @owner_root.id,
      direction: "child"
    }, as: :json

    assert_response :ok
    assert_equal [ @owner_b.id, @owner_a.id ], @owner_root.children.order(:sequence).pluck(:id)
  end

  # --- link_drop -------------------------------------------------------------

  test "link_drop is forbidden when the source is not readable" do
    sign_in_as(@stranger)

    assert_no_difference -> { Creative.count } do
      post link_drop_creatives_path, params: {
        dragged_id: @owner_a.id, target_id: @stranger_root.id, direction: "child"
      }, as: :json
    end

    assert_response :forbidden
  end

  test "link_drop is forbidden when the receiving container is not writable" do
    sign_in_as(@stranger)

    assert_no_difference -> { Creative.count } do
      post link_drop_creatives_path, params: {
        dragged_id: @stranger_a.id, target_id: @owner_a.id, direction: "child"
      }, as: :json
    end

    assert_response :forbidden
  end

  test "link_drop cannot insert into another user's private link shell" do
    share!(@owner_root, @collaborator, :write)
    foreign_shell = Creative.create!(
      user: @stranger,
      parent: @stranger_root,
      origin_id: @owner_a.id,
      sequence: 1
    )
    sign_in_as(@collaborator)

    assert_no_difference -> { Creative.count } do
      params = { dragged_id: @owner_b.id, target_id: foreign_shell.id, direction: "child" }
      post link_drop_creatives_path, params: params, as: :json
    end

    assert_response :forbidden
  end

  # Read is the whole requirement on the source: the drop creates a new shell
  # pointing at the same origin and never writes to the dragged Creative.
  test "link_drop only needs read on the source creative" do
    share!(@owner_root, @collaborator, :read)
    sign_in_as(@collaborator)

    assert_difference -> { Creative.count }, 1 do
      post link_drop_creatives_path, params: {
        dragged_id: @owner_a.id, target_id: @collaborator_root.id, direction: "child"
      }, as: :json
    end

    assert_response :ok
    linked = Creative.find(JSON.parse(response.body)["creative_id"])
    assert_equal @owner_a.id, linked.origin_id
    assert_equal @collaborator_root.id, linked.parent_id
  end

  # A root target has no parent, so the target itself is the only container the
  # check can anchor on.
  test "link_drop next to a root target checks the target itself" do
    share!(@owner_root, @collaborator, :read)
    sign_in_as(@collaborator)

    assert_difference -> { Creative.count }, 1 do
      post link_drop_creatives_path, params: {
        dragged_id: @owner_a.id, target_id: @collaborator_root.id, direction: "up"
      }, as: :json
    end
    assert_response :ok

    assert_no_difference -> { Creative.count } do
      post link_drop_creatives_path, params: {
        dragged_id: @owner_a.id, target_id: @owner_root.id, direction: "up"
      }, as: :json
    end
    assert_response :forbidden
  end

  # --- status code separation ------------------------------------------------

  test "malformed input still answers 422, not 403" do
    sign_in_as(@owner)

    post reorder_creatives_path, params: {
      dragged_id: @owner_a.id, target_id: @owner_b.id, direction: "sideways"
    }, as: :json
    assert_response :unprocessable_entity

    post reorder_creatives_path, params: {
      dragged_id: 0, target_id: 0, direction: "up"
    }, as: :json
    assert_response :unprocessable_entity
  end

  private

  def create_user(handle)
    User.create!(
      email: "#{handle}@example.com",
      password: TEST_PASSWORD,
      name: handle,
      email_verified_at: Time.current,
      notifications_enabled: false
    )
  end

  def share!(creative, user, permission)
    perform_enqueued_jobs do
      CreativeShare.create!(creative: creative, user: user, permission: permission)
    end
  end
end
