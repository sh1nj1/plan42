require "test_helper"

class CreativeSelfOriginTest < ActiveSupport::TestCase
  test "origin_id cannot be the same as id" do
    user = users(:one)
    creative = Creative.create!(description: "Self Origin Test", user: user)

    # Attempt to set origin to self
    creative.origin_id = creative.id

    assert_not creative.valid?
    assert_includes creative.errors[:origin_id], "cannot be the same as id"

    assert_raises(ActiveRecord::RecordInvalid) do
      creative.save!
    end
  end
end
