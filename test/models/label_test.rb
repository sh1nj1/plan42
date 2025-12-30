require "test_helper"

class LabelTest < ActiveSupport::TestCase
  test "label linked to creative is readable by users with creative read permission" do
    creative = creatives(:tshirt)
    user = users(:two)
    # Label is now required to have a creative. Name is delegated.
    label = Label.create!(creative: creative, owner: users(:one))

    CreativeShare.create!(creative: creative, user: user, permission: :read)

    assert label.readable_by?(user), "User with read permission should be able to read label"
  end

  test "label linked to creative is not readable by users without creative permission" do
    creative = creatives(:tshirt)
    user = users(:two)
    label = Label.create!(creative: creative, owner: users(:one))

    refute label.readable_by?(user), "User without permission should not be able to read label"
  end

  test "label respects no_access permission on creative" do
    creative = creatives(:tshirt)
    user = users(:two)
    label = Label.create!(creative: creative, owner: users(:one))

    CreativeShare.create!(creative: creative, user: user, permission: :no_access)

    refute label.readable_by?(user), "User with no_access should not be able to read label"
  end
end
