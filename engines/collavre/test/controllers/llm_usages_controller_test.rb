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
      input_tokens: 0, output_tokens: 2, raw_usage: { internal_marker: "usage-payload-should-not-render" })
    %w[en ko].each do |locale|
      user.update!(locale: locale)
      get llm_usages_path, params: { locale: locale, group: "owner" }
      assert_response :success
      assert_select "h1", I18n.t("collavre.llm_usages.title", locale: locale)
      assert_select "tbody tr", 1
      assert_select "td", text: user.name
      assert_select "td", text: "0"
      refute_includes response.body, "usage-payload-should-not-render"
    end
  end
  test "lists per-tool statistics in both languages and JSON" do
    user = users(:two)
    sign_in_as(user, password: "password")
    requester = users(:three)
    [ [ true, 10 ], [ false, 31 ] ].each_with_index do |(succeeded, duration), index|
      Collavre::ToolUsage.create!(event_key: "tool-#{index}", execution_id: "tools", source: "mcp", tool_name: "cron_list",
        succeeded: succeeded, duration_ms: duration, owner_id: user.id, requester_id: requester.id,
        requester_ids: [ requester.id ], requester_kind: "human", occurred_at: Time.current)
    end
    %w[en ko].each do |locale|
      user.update!(locale: locale)
      get llm_usages_path, params: { locale: locale }
      assert_response :success
      assert_select "#tool-usage-title", I18n.t("collavre.llm_usages.tools.title", locale: locale)
      assert_select ".usage-report__tools tbody tr", 1
      assert_select ".usage-report__tools td", text: "cron_list"
      assert_select ".usage-report__tools td", text: I18n.t("collavre.llm_usages.tools.milliseconds", value: "21", locale: locale)
      assert_select "select[name=requester_id] option", text: requester.name
    end
    get llm_usages_path(format: :json)
    assert_equal [ { "tool_name" => "cron_list", "calls" => 2, "failures" => 1, "average_duration_ms" => 21 } ],
      response.parsed_body["tools"]
    user.update!(locale: "en")
    get llm_usages_path, params: { locale: "en", requester_id: user.id }
    assert_select ".usage-report__tools p", text: I18n.t("collavre.llm_usages.tools.empty", locale: :en)
  end
end
