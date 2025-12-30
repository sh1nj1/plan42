require "test_helper"

class LabelTest < ActiveSupport::TestCase
  test "label linked to creative is readable by users with creative read permission" do
    creative = creatives(:tshirt)
    user = users(:two)
    label = Label.create!(name: "Test Label", creative: creative, owner: users(:one))

    CreativeShare.create!(creative: creative, user: user, permission: :read)

    assert label.readable_by?(user), "User with read permission should be able to read label"
  end

  test "label linked to creative is not readable by users without creative permission" do
    creative = creatives(:tshirt)
    user = users(:two)
    label = Label.create!(name: "Test Label", creative: creative, owner: users(:one))

    refute label.readable_by?(user), "User without permission should not be able to read label"
  end

  test "label without creative is readable by owner" do
    label = Label.create!(name: "Test Label", owner: users(:one))

    assert label.readable_by?(users(:one)), "Owner should be able to read their own label"
    refute label.readable_by?(users(:two)), "Non-owner should not be able to read label"
  end

  test "label without creative and without owner is readable by everyone" do
    label = Label.create!(name: "Public Label", owner: nil)

    assert label.readable_by?(users(:one)), "Public label should be readable by any user"
    assert label.readable_by?(users(:two)), "Public label should be readable by any user"
  end

  test "label respects no_access permission on creative" do
    creative = creatives(:tshirt)
    user = users(:two)
    label = Label.create!(name: "Test Label", creative: creative, owner: users(:one))

    CreativeShare.create!(creative: creative, user: user, permission: :no_access)

    refute label.readable_by?(user), "User with no_access should not be able to read label"
  end
end
