require_relative "../../test_helper"

class CollavreLinear::AccountTest < ActiveSupport::TestCase
  def setup
    @user = Collavre.user_class.create!(
      email: "linear-test@example.com",
      name: "Linear Test User",
      password: TEST_PASSWORD,
      password_confirmation: TEST_PASSWORD,
      timezone: "UTC"
    )
    @other_user = Collavre.user_class.create!(
      email: "linear-other@example.com",
      name: "Linear Other User",
      password: TEST_PASSWORD,
      password_confirmation: TEST_PASSWORD,
      timezone: "UTC"
    )
  end

  test "encrypts access_token" do
    a = CollavreLinear::Account.create!(user: @user, linear_uid: "u1", access_token: "secret-token")
    raw = CollavreLinear::Account.connection.select_value(
      "SELECT access_token FROM linear_accounts WHERE id = #{a.id}")
    refute_equal "secret-token", raw
  end

  test "model validation rejects duplicate linear_uid" do
    CollavreLinear::Account.create!(user: @user, linear_uid: "u1", access_token: "token-a")
    dup = CollavreLinear::Account.new(user: @other_user, linear_uid: "u1", access_token: "token-b")
    refute dup.valid?
    assert_includes dup.errors[:linear_uid], "has already been taken"
  end

  test "DB unique index raises RecordNotUnique when validation is bypassed" do
    CollavreLinear::Account.create!(user: @user, linear_uid: "u1", access_token: "token-a")
    dup = CollavreLinear::Account.new(user: @other_user, linear_uid: "u1", access_token: "token-b")
    assert_raises(ActiveRecord::RecordNotUnique) do
      dup.save(validate: false)
    end
  end

  test "token_expired? returns true when token_expires_at is in the past" do
    account = CollavreLinear::Account.new(
      user: @user,
      linear_uid: "u2",
      access_token: "token",
      token_expires_at: 1.hour.ago
    )
    assert account.token_expired?
  end

  test "token_expired? returns false when token_expires_at is in the future" do
    account = CollavreLinear::Account.new(
      user: @user,
      linear_uid: "u3",
      access_token: "token",
      token_expires_at: 1.hour.from_now
    )
    assert_not account.token_expired?
  end

  test "token_expired? returns false when token_expires_at is nil" do
    account = CollavreLinear::Account.new(
      user: @user,
      linear_uid: "u4",
      access_token: "token",
      token_expires_at: nil
    )
    assert_not account.token_expired?
  end

  test "token_expiring_soon? returns true when token expires within default window" do
    account = CollavreLinear::Account.new(
      user: @user,
      linear_uid: "u5",
      access_token: "token",
      token_expires_at: 3.minutes.from_now
    )
    assert account.token_expiring_soon?
  end

  test "token_expiring_soon? returns false when token expires outside default window" do
    account = CollavreLinear::Account.new(
      user: @user,
      linear_uid: "u6",
      access_token: "token",
      token_expires_at: 10.minutes.from_now
    )
    assert_not account.token_expiring_soon?
  end

  test "token_expiring_soon? accepts custom within parameter" do
    account = CollavreLinear::Account.new(
      user: @user,
      linear_uid: "u7",
      access_token: "token",
      token_expires_at: 8.minutes.from_now
    )
    assert account.token_expiring_soon?(within: 10.minutes)
    assert_not account.token_expiring_soon?(within: 5.minutes)
  end

  test "belongs to user" do
    account = CollavreLinear::Account.create!(
      user: @user,
      linear_uid: "u8",
      access_token: "token"
    )
    assert_equal @user, account.user
  end

  test "destroying the owning user cascades away the account and its project links" do
    creative = Collavre::Creative.create!(description: "<p>Root</p>", user: @user)
    account = CollavreLinear::Account.create!(user: @user, linear_uid: "u-del", access_token: "token")
    link = CollavreLinear::ProjectLink.create!(
      creative: creative, account: account, linear_project_id: "proj-del", team_id: "team-del"
    )

    # The RESTRICT FK on linear_project_links.account_id would reject the account
    # delete without the dependent cascade, breaking user deletion entirely.
    assert_nothing_raised { @user.destroy! }

    assert_not CollavreLinear::Account.exists?(account.id)
    assert_not CollavreLinear::ProjectLink.exists?(link.id)
  end

  test "encrypts refresh_token" do
    a = CollavreLinear::Account.create!(
      user: @user,
      linear_uid: "u9",
      access_token: "access",
      refresh_token: "refresh-secret"
    )
    raw = CollavreLinear::Account.connection.select_value(
      "SELECT refresh_token FROM linear_accounts WHERE id = #{a.id}")
    refute_equal "refresh-secret", raw
  end
end
