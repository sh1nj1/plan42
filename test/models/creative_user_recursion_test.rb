require "test_helper"

class CreativeUserRecursionTest < ActiveSupport::TestCase
  test "avoids infinite loop in user method with circular origin" do
    user = users(:one)

    # A -> B -> A cycle
    a = Creative.create!(description: "A", user: user)
    b = Creative.create!(description: "B", user: user, origin: a)

    # Force cycle by bypassing validations if necessary, or just setting origin_id directly
    # Using update_columns to bypass potential validations preventing cycle creation if any
    a.update_columns(origin_id: b.id)

    # Now accessing a.user should not crash
    assert_nothing_raised do
      assert_equal user, a.user
    end

    assert_nothing_raised do
      assert_equal user, b.user
    end
  end
end
