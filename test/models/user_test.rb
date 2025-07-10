require "test_helper"

class UserTest < ActiveSupport::TestCase
  test "requires valid email" do
    user = User.new(email: "bad", password: "secret", password_confirmation: "secret", name: "Bad")
    assert_not user.valid?
    assert_includes user.errors[:email], "is invalid"
  end

  test "requires unique email" do
    User.create!(email: "taken@example.com", password: "secret", name: "Taken")
    user = User.new(email: "taken@example.com", password: "secret", name: "Taken")
    assert_not user.valid?
    assert_includes user.errors[:email], "has already been taken"
  end
end
