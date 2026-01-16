require "test_helper"

class Creatives::InheritedShareBuilderTest < ActiveSupport::TestCase
  setup do
    @owner = users(:one)
    @shared_user = users(:two)
  end

  test "propagate_share creates inherited shares for all descendants" do
    parent = Creative.create!(user: @owner, description: "Parent")
    child = Creative.create!(user: @owner, parent: parent, description: "Child")
    grandchild = Creative.create!(user: @owner, parent: child, description: "Grandchild")

    share = CreativeShare.create!(creative: parent, user: @shared_user, permission: :read)

    # After creating share, inherited shares should exist for descendants
    assert CreativeShare.exists?(creative: child, user: @shared_user, inherited: true)
    assert CreativeShare.exists?(creative: grandchild, user: @shared_user, inherited: true)
  end

  test "remove_inherited_shares removes inherited shares from descendants" do
    parent = Creative.create!(user: @owner, description: "Parent")
    child = Creative.create!(user: @owner, parent: parent, description: "Child")

    share = CreativeShare.create!(creative: parent, user: @shared_user, permission: :read)
    assert CreativeShare.exists?(creative: child, user: @shared_user, inherited: true)

    share.destroy

    assert_not CreativeShare.exists?(creative: child, user: @shared_user)
  end

  test "propagate_to_new_creative creates inherited shares from parent's shares" do
    parent = Creative.create!(user: @owner, description: "Parent")
    CreativeShare.create!(creative: parent, user: @shared_user, permission: :write)

    # Create child - should automatically get inherited share
    child = Creative.create!(user: @owner, parent: parent, description: "Child")

    share = CreativeShare.find_by(creative: child, user: @shared_user)
    assert_not_nil share
    assert share.inherited?
    assert_equal "write", share.permission
  end

  test "update_inherited_shares_on_parent_change removes old and creates new inherited shares" do
    # Create two separate trees
    old_parent = Creative.create!(user: @owner, description: "Old Parent")
    new_parent = Creative.create!(user: @owner, description: "New Parent")
    child = Creative.create!(user: @owner, parent: old_parent, description: "Child")

    # Share old parent with user A, new parent with user B
    user_a = @shared_user
    user_b = User.create!(email: "userb@test.com", password: "password", name: "User B")

    CreativeShare.create!(creative: old_parent, user: user_a, permission: :read)
    CreativeShare.create!(creative: new_parent, user: user_b, permission: :write)

    # Verify child has inherited share from old parent
    assert CreativeShare.exists?(creative: child, user: user_a, inherited: true)
    assert_not CreativeShare.exists?(creative: child, user: user_b)

    # Move child to new parent
    child.update!(parent: new_parent)

    # Verify old inherited share is removed and new one is created
    assert_not CreativeShare.exists?(creative: child, user: user_a, inherited: true)
    assert CreativeShare.exists?(creative: child, user: user_b, inherited: true)
  end

  test "moving creative with descendants updates all inherited shares" do
    old_parent = Creative.create!(user: @owner, description: "Old Parent")
    new_parent = Creative.create!(user: @owner, description: "New Parent")
    child = Creative.create!(user: @owner, parent: old_parent, description: "Child")
    grandchild = Creative.create!(user: @owner, parent: child, description: "Grandchild")

    user_a = @shared_user
    user_b = User.create!(email: "userb@test.com", password: "password", name: "User B")

    CreativeShare.create!(creative: old_parent, user: user_a, permission: :read)
    CreativeShare.create!(creative: new_parent, user: user_b, permission: :write)

    # Verify both child and grandchild have inherited shares from old parent
    assert CreativeShare.exists?(creative: child, user: user_a, inherited: true)
    assert CreativeShare.exists?(creative: grandchild, user: user_a, inherited: true)

    # Move child (and its descendants) to new parent
    child.update!(parent: new_parent)

    # Verify old inherited shares are removed
    assert_not CreativeShare.exists?(creative: child, user: user_a, inherited: true)
    assert_not CreativeShare.exists?(creative: grandchild, user: user_a, inherited: true)

    # Verify new inherited shares are created
    assert CreativeShare.exists?(creative: child, user: user_b, inherited: true)
    assert CreativeShare.exists?(creative: grandchild, user: user_b, inherited: true)
  end
end
