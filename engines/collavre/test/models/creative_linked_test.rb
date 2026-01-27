require "test_helper"

class CreativeLinkedTest < ActiveSupport::TestCase
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
