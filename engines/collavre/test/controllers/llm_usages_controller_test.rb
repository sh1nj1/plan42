require "test_helper"

class LlmUsagesControllerTest < ActionDispatch::IntegrationTest
  test "requires authentication" do
    get llm_usages_path
    assert_response :redirect
  end

  test "renders localized HTML and JSON without exposing raw logs" do
    sign_in_as(users(:two), password: "password")
    get llm_usages_path, params: { locale: "en" }
    assert_response :success
    assert_select "h1", I18n.t("collavre.llm_usages.title", locale: :en)
    assert_select "select[name=period] option", 3
    get llm_usages_path(format: :json)
    assert_response :success
    assert_equal "Asia/Seoul", response.parsed_body["timezone"]
    assert_equal [], response.parsed_body["rows"]
    get llm_usages_path, params: { period: "not-valid" }
    assert_response :unprocessable_entity
  end

  test "renders reported zero and unknown cells in both languages" do
    user = users(:two)
    sign_in_as(user, password: "password")
    Collavre::LlmUsage.create!(event_key: "view", execution_id: "view", owner_id: user.id,
      requester_kind: "unknown", vendor: "openai", model: "test", occurred_at: Time.current,
      input_tokens: 0, output_tokens: 2, raw_usage: { secret: "secret-usage-payload-should-not-render" })
    %w[en ko].each do |locale|
      user.update!(locale: locale)
      get llm_usages_path, params: { locale: locale, group: "owner" }
      assert_response :success
      assert_select "h1", I18n.t("collavre.llm_usages.title", locale: locale)
      assert_select "tbody tr", 1
      assert_select "td", text: user.name
      assert_select "td", text: "0"
      refute_includes response.body, "secret-usage-payload-should-not-render"
    end
  end
end
