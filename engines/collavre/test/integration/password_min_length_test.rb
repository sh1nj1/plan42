require "test_helper"

class PasswordMinLengthTest < ActionDispatch::IntegrationTest
  setup do
    # Reset to default
    SystemSetting.find_by(key: "password_min_length")&.destroy
    Rails.cache.clear
  end

  teardown do
    # Clean up
    SystemSetting.find_by(key: "password_min_length")&.destroy
    Rails.cache.clear
  end

  test "sign-up form has default minlength attribute on password field" do
    get new_user_path

    assert_response :success
    assert_select "input[name='user[password]'][minlength='#{SystemSetting::DEFAULT_PASSWORD_MIN_LENGTH}']"
  end

  test "sign-up form has custom minlength attribute on password field" do
    SystemSetting.create!(key: "password_min_length", value: "12")
    Rails.cache.clear

    get new_user_path

    assert_response :success
    assert_select "input[name='user[password]'][minlength='12']"
  end

  test "sign-up rejects password shorter than admin-configured minimum" do
    SystemSetting.create!(key: "password_min_length", value: "12")
    Rails.cache.clear

    assert_no_difference("User.count") do
      post users_path, params: {
        user: {
          email: "newuser@example.com",
          password: "short1234",  # 9 chars, less than 12
          password_confirmation: "short1234",
          name: "New User"
        }
      }
    end

    assert_response :unprocessable_entity
  end

  test "sign-up accepts password meeting admin-configured minimum" do
    SystemSetting.create!(key: "password_min_length", value: "12")
    Rails.cache.clear

    assert_difference("User.count", 1) do
      post users_path, params: {
        user: {
          email: "newuser@example.com",
          password: "validpassword123",  # 16 chars, meets 12 minimum
          password_confirmation: "validpassword123",
          name: "New User"
        }
      }
    end

    assert_redirected_to new_session_path
  end

  test "password change form has custom minlength attribute" do
    user = User.create!(email: "pwchange@example.com", password: TEST_PASSWORD, name: "PwChange", email_verified_at: Time.current)
    sign_in_as(user)

    SystemSetting.create!(key: "password_min_length", value: "15")
    Rails.cache.clear

    get edit_password_user_path(user)

    assert_response :success
    assert_select "input[name='user[password]'][minlength='15']"
  end

  test "password change rejects password shorter than admin-configured minimum" do
    user = User.create!(email: "pwchange2@example.com", password: TEST_PASSWORD, name: "PwChange2", email_verified_at: Time.current)
    sign_in_as(user)

    SystemSetting.create!(key: "password_min_length", value: "12")
    Rails.cache.clear

    patch update_password_user_path(user), params: {
      user: {
        current_password: TEST_PASSWORD,
        password: "short123",  # 8 chars, less than 12
        password_confirmation: "short123"
      }
    }

    assert_response :unprocessable_entity
    user.reload
    assert user.authenticate(TEST_PASSWORD), "Password should not have changed"
  end

  test "password change accepts password meeting admin-configured minimum" do
    user = User.create!(email: "pwchange3@example.com", password: TEST_PASSWORD, name: "PwChange3", email_verified_at: Time.current)
    sign_in_as(user)

    SystemSetting.create!(key: "password_min_length", value: "12")
    Rails.cache.clear

    new_password = "newvalidpass123"
    patch update_password_user_path(user), params: {
      user: {
        current_password: TEST_PASSWORD,
        password: new_password,
        password_confirmation: new_password
      }
    }

    assert_redirected_to user_path(user)
    user.reload
    assert user.authenticate(new_password), "Password should have been updated"
  end

  test "login form does not have minlength attribute on password field" do
    get new_session_path

    assert_response :success
    # Login form should not have minlength constraint
    assert_select "input[name='password']:not([minlength])"
  end

  # Password reset flow tests
  test "password reset form has minlength attribute" do
    user = User.create!(email: "reset@example.com", password: TEST_PASSWORD, name: "Reset", email_verified_at: Time.current)
    token = user.generate_token_for(:password_reset)

    SystemSetting.create!(key: "password_min_length", value: "15")
    Rails.cache.clear

    get edit_password_path(token: token)

    assert_response :success
    assert_select "input[name='password'][minlength='15']"
  end

  test "password reset rejects short password" do
    user = User.create!(email: "reset2@example.com", password: TEST_PASSWORD, name: "Reset2", email_verified_at: Time.current)
    token = user.generate_token_for(:password_reset)

    SystemSetting.create!(key: "password_min_length", value: "12")
    Rails.cache.clear

    patch password_path(token), params: {
      password: "short123",  # 8 chars, less than 12
      password_confirmation: "short123"
    }

    # Controller redirects on validation failure
    assert_redirected_to edit_password_path(token)
    user.reload
    assert user.authenticate(TEST_PASSWORD), "Password should not have changed"
  end

  test "password reset accepts valid password" do
    user = User.create!(email: "reset3@example.com", password: TEST_PASSWORD, name: "Reset3", email_verified_at: Time.current)
    token = user.generate_token_for(:password_reset)

    SystemSetting.create!(key: "password_min_length", value: "12")
    Rails.cache.clear

    new_password = "newvalidpass123"
    patch password_path(token), params: {
      password: new_password,
      password_confirmation: new_password
    }

    assert_redirected_to new_session_path
    user.reload
    assert user.authenticate(new_password), "Password should have been updated"
  end
end
