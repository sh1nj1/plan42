require "test_helper"

class CreativeLinkedTest < ActiveSupport::TestCase
  test "link removal checks the shell owner and retains the access scope boundary" do
    owner = users(:one)
    viewer = users(:two)
    original = Creative.create!(user: owner, description: "Original")
    link = Creative.create!(user: viewer, origin: original)

    assert_equal owner, link.user
    assert link.destroyable_by?(viewer)
    assert_not link.destroyable_by?(nil)
    assert original.destroyable_by?(owner)
    assert_not original.destroyable_by?(viewer)
    Collavre::Kollavy::AccessScope.stub :allowed?, false do
      assert_not link.destroyable_by?(viewer)
    end
  end

  test "direct shell destruction preserves links while original destruction still cascades" do
    original = Creative.create!(user: users(:one), description: "Original")
    link = Creative.create!(user: users(:two), origin: original)
    downstream = Creative.create!(user: users(:one), origin: link)

    link.destroy!

    assert_equal original.id, downstream.reload.origin_id
    assert_equal original, downstream.effective_origin
    original.destroy!
    assert_not Creative.exists?(downstream.id)
  end

  test "aborted shell destruction rolls back downstream repointing" do
    original = Creative.create!(user: users(:one), description: "Original")
    link = Creative.create!(user: users(:two), origin: original)
    downstream = Creative.create!(user: users(:one), origin: link)
    link.define_singleton_method(:preserve_downstream_links) do
      super()
      throw :abort
    end

    assert_not link.destroy
    assert_equal link.id, downstream.reload.origin_id
    assert Creative.exists?(link.id)
  end

  test "children created under a linked creative are redirected to origin" do
    owner = User.create!(email: "owner@example.com", password: "password", name: "Owner")
    viewer = User.create!(email: "viewer@example.com", password: "password", name: "Viewer")

    Current.session = Struct.new(:user).new(owner)
    original_creative = Creative.create!(user: owner, description: "Original Creative")

    # Share with viewer
    CreativeShare.create!(creative: original_creative, user: viewer, permission: :read)

    # Viewer creates a linked creative
    Current.session = Struct.new(:user).new(viewer)
    linked_creative = Creative.create!(user: viewer, origin: original_creative, description: "Linked Creative")

    # Viewer creates a new creative under the linked creative
    child_creative = Creative.create!(user: viewer, parent: linked_creative, description: "Child of Linked Creative")

    # Assert that the parent is redirected to the origin
    assert_equal original_creative, child_creative.parent
    assert_not_equal linked_creative, child_creative.parent
  end
end
