require "test_helper"

class CreativeSelfOriginTest < ActiveSupport::TestCase
  test "origin_id cannot be the same as id" do
    user = users(:one)

    creative = Creative.create!(description: "Self Origin Test", user: user)

    # origin_id is attr_readonly, so a normal assignment would raise before the
    # validation could run. Inject the self-reference at the SQL level with
    # update_all (bypasses the readonly guard), then reload so the record carries
    # origin_id == id pointing at a real row — exactly the corrupt state the
    # validation exists to reject.
    Creative.where(id: creative.id).update_all(origin_id: creative.id)
    creative.reload

    assert_not creative.valid?
    assert_includes creative.errors[:origin_id], "cannot be the same as id"

    assert_raises(ActiveRecord::RecordInvalid) do
      creative.save!
    end
  end
end
