require "test_helper"

class UserTest < ActiveSupport::TestCase
  test "requires valid email" do
    user = User.new(email: "bad", password: "password123", password_confirmation: "password123", name: "Bad")
    assert_not user.valid?
    assert_includes user.errors[:email], "is invalid"
  end

  test "requires unique email" do
    User.create!(email: "taken@example.com", password: "password123", name: "Taken")
    user = User.new(email: "taken@example.com", password: "password123", name: "Taken")
    assert_not user.valid?
    assert_includes user.errors[:email], "has already been taken"
  end

  test "requires password minimum length" do
    user = User.new(email: "short@example.com", password: "short", name: "Short")
    assert_not user.valid?
    assert user.errors.of_kind?(:password, :too_short),
      "Expected :too_short error on password"
  end

  test "accepts password meeting minimum length" do
    user = User.new(email: "long@example.com", password: "password123", name: "Long")
    user.valid?
    assert_not user.errors.of_kind?(:password, :too_short),
      "Should not have :too_short error for valid password"
  end

  test "enforces custom password minimum length from system setting" do
    # Set custom min length
    SystemSetting.find_or_create_by!(key: "password_min_length").update!(value: "12")
    Rails.cache.clear

    # 10 chars should fail when min is 12
    user = User.new(email: "custom@example.com", password: "1234567890", name: "Custom")
    assert_not user.valid?
    assert user.errors.of_kind?(:password, :too_short)

    # 12 chars should pass
    user.password = "123456789012"
    user.valid?
    assert_not user.errors.of_kind?(:password, :too_short)
  end

  test "password min length is capped at 72 (bcrypt limit)" do
    # Even if DB has value > 72, it should be capped
    SystemSetting.find_or_create_by!(key: "password_min_length").update!(value: "100")
    Rails.cache.clear

    assert_equal 72, SystemSetting.password_min_length,
      "password_min_length should be capped at 72"

    # 72-char password should pass
    user = User.new(email: "max@example.com", password: "a" * 72, name: "Max")
    user.valid?
    assert_not user.errors.of_kind?(:password, :too_short),
      "72-char password should pass when min is capped at 72"
  end

  test "nullifies shares created by user as sharer when destroyed" do
    sharer = users(:two)
    recipient = users(:three)
    creative = creatives(:tshirt)

    share = CreativeShare.create!(creative: creative, user: recipient, shared_by: sharer, permission: :read)

    assert_nothing_raised { sharer.destroy! }
    assert_nil share.reload.shared_by_id
  end
end
