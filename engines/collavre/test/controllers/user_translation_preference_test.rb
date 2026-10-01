require "test_helper"

class UserTranslationPreferenceTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:one)
    sign_in_as @user, password: "password"
  end

  test "profile preference persists across sessions and remains separate per user" do
    patch user_path(@user), params: { user: { auto_translation_enabled: "0" } }
    assert_response :redirect
    refute @user.reload.auto_translation_enabled?
    assert users(:two).auto_translation_enabled?
    sign_out
    sign_in_as @user, password: "password"
    get user_path(@user)
    assert_select 'input[type=checkbox][name="user[auto_translation_enabled]"]:not([checked])', count: 1
    patch user_path(@user), params: { user: { auto_translation_enabled: "1" } }
    assert @user.reload.auto_translation_enabled?
  end

  test "another user cannot change the preference and anonymous update requires authentication" do
    sign_out
    sign_in_as users(:two), password: "password"
    patch user_path(users(:three)), params: { user: { auto_translation_enabled: "0" } }
    assert_response :forbidden
    assert users(:three).reload.auto_translation_enabled?
    sign_out
    patch user_path(@user), params: { user: { auto_translation_enabled: "0" } }
    assert_response :redirect
    assert @user.reload.auto_translation_enabled?
  end

  test "profile checkbox uses English and Korean labels" do
    { "en" => "Automatically translate content", "ko" => "콘텐츠 자동 번역" }.each do |locale, label|
      @user.update!(locale: locale)
      get user_path(@user)
      assert_select 'label[for=user_auto_translation_enabled]', text: label
      assert_select 'input[type=checkbox][name="user[auto_translation_enabled]"][checked]', count: 1
    end
  end

  test "new and existing users default to automatic translation" do
    assert Collavre::User.new.auto_translation_enabled?
    assert users(:two).reload.auto_translation_enabled?
    assert_equal true, Collavre::User.column_defaults["auto_translation_enabled"]
  end
end
