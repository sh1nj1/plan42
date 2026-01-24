require "test_helper"

class LocaleTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:one)
    @user.update!(locale: "ko")
  end

  test "should use user locale for authenticated user on public page" do
    sign_in_as @user, password: "password"
    get root_path, headers: { "HTTP_ACCEPT_LANGUAGE" => "en" }

    assert_response :success
    assert_match "하나 이상의 크리에이티브를 선택하세요.", response.body
  end
end
