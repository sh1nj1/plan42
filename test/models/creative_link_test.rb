require "test_helper"

class CreativeLinkTest < ActiveSupport::TestCase
  setup do
    @user = users(:one)
    @parent = Creative.create!(user: @user, description: "Parent")
    @origin = Creative.create!(user: @user, description: "Origin")
    @child_of_origin = Creative.create!(user: @user, parent: @origin, description: "Child of Origin")
  end

  test "creating link builds virtual hierarchy" do
    link = CreativeLink.create!(
      parent: @parent,
      origin: @origin,
      created_by: @user
    )

    # parent -> origin (virtual)
    assert VirtualCreativeHierarchy.exists?(
      ancestor_id: @parent.id,
      descendant_id: @origin.id,
      creative_link_id: link.id
    ), "Should create virtual hierarchy: parent -> origin"

    # parent -> child_of_origin (virtual)
    assert VirtualCreativeHierarchy.exists?(
      ancestor_id: @parent.id,
      descendant_id: @child_of_origin.id,
      creative_link_id: link.id
    ), "Should create virtual hierarchy: parent -> child_of_origin"
  end

  test "destroying link removes virtual hierarchy" do
    link = CreativeLink.create!(
      parent: @parent,
      origin: @origin,
      created_by: @user
    )

    initial_count = VirtualCreativeHierarchy.where(creative_link_id: link.id).count
    assert initial_count > 0, "Should have created virtual hierarchy entries"

    link.destroy

    assert_equal 0, VirtualCreativeHierarchy.where(creative_link_id: link.id).count,
      "Should have deleted all virtual hierarchy entries"
  end

  test "prevents circular reference when origin contains parent in its subtree" do
    # Create hierarchy: origin -> child_of_origin (already in setup)
    # Try to link from child_of_origin to origin - this would create a cycle
    # because origin's subtree contains child_of_origin

    link = CreativeLink.new(
      parent: @child_of_origin,  # child_of_origin is in origin's subtree
      origin: @origin,           # origin's subtree contains child_of_origin
      created_by: @user
    )

    # This should fail because origin's subtree (via CreativeHierarchy) contains child_of_origin
    assert_not link.valid?, "Should not allow circular reference"
    assert_includes link.errors[:origin], "would create a circular reference"
  end

  test "prevents linking to existing descendant" do
    # Create hierarchy: parent -> child
    child = Creative.create!(user: @user, parent: @parent, description: "Child")

    # Try to create link from parent to child (already descendant)
    link = CreativeLink.new(
      parent: @parent,
      origin: child,
      created_by: @user
    )

    assert_not link.valid?, "Should not allow linking to existing descendant"
    assert_includes link.errors[:origin], "is already a descendant of parent"
  end

  test "validates uniqueness of parent and origin combination" do
    CreativeLink.create!(
      parent: @parent,
      origin: @origin,
      created_by: @user
    )

    duplicate = CreativeLink.new(
      parent: @parent,
      origin: @origin,
      created_by: @user
    )

    assert_not duplicate.valid?, "Should not allow duplicate link"
    assert duplicate.errors[:parent_id].present?
  end

  test "virtual hierarchy includes parent's ancestors" do
    # Create hierarchy: grandparent -> parent
    grandparent = Creative.create!(user: @user, description: "Grandparent")
    @parent.update!(parent: grandparent)

    link = CreativeLink.create!(
      parent: @parent,
      origin: @origin,
      created_by: @user
    )

    # grandparent -> origin (virtual, through parent's link)
    assert VirtualCreativeHierarchy.exists?(
      ancestor_id: grandparent.id,
      descendant_id: @origin.id,
      creative_link_id: link.id
    ), "Should create virtual hierarchy: grandparent -> origin"

    # grandparent -> child_of_origin (virtual)
    assert VirtualCreativeHierarchy.exists?(
      ancestor_id: grandparent.id,
      descendant_id: @child_of_origin.id,
      creative_link_id: link.id
    ), "Should create virtual hierarchy: grandparent -> child_of_origin"
  end
end
