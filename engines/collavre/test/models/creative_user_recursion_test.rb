require "test_helper"

class CreativeUserRecursionTest < ActiveSupport::TestCase
  test "avoids infinite loop in user method with circular origin" do
    user = users(:one)

    # A -> B -> A cycle
    a = Creative.create!(description: "A", user: user)
    b = Creative.create!(description: "B", user: user, origin: a)

    # origin_id is attr_readonly (immutable after create), so update_columns would
    # raise. Force the cycle at the SQL level with update_all, which bypasses the
    # readonly guard.
    Creative.where(id: a.id).update_all(origin_id: b.id)

    # Now accessing a.user should not crash
    assert_nothing_raised do
      assert_equal user.id, a.user.id
    end

    assert_nothing_raised do
      assert_equal user.id, b.user.id
    end
  end
end
