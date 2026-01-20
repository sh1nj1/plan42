require "test_helper"

class CreativePlansControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = User.create!(email: "plan@example.com", password: TEST_PASSWORD, name: "Planner", email_verified_at: Time.current)
    @plan_creative = Creative.create!(user: @user, description: "Launch")
    @plan = Plan.create!(creative: @plan_creative, owner: @user, target_date: Date.today)
    @creative = Creative.create!(user: @user, description: "Root")
    sign_in_as(@user)
  end

  test "applies plan tags to creatives via HTML" do
    post creative_plan_path, params: { plan_id: @plan.id, creative_ids: @creative.id }

    assert_redirected_to creatives_path(select_mode: 1)
    assert_equal 1, @creative.tags.where(label: @plan).count
    assert_equal I18n.t("creatives.index.plan_tags_applied", default: "Plan tags applied to selected creatives."), flash[:notice]
  end

  test "applies plan tags to creatives via JSON" do
    post creative_plan_path, params: { plan_id: @plan.id, creative_ids: @creative.id }, as: :json

    assert_response :ok
    json_response = JSON.parse(response.body)
    assert_equal I18n.t("creatives.index.plan_tags_applied", default: "Plan tags applied to selected creatives."), json_response["message"]
    assert_equal 1, @creative.tags.where(label: @plan).count
  end

  test "removes plan tags from creatives via HTML" do
    @creative.tags.create!(label: @plan)

    delete creative_plan_path, params: { plan_id: @plan.id, creative_ids: @creative.id }

    assert_redirected_to creatives_path(select_mode: 1)
    assert_not @creative.tags.exists?(label: @plan)
    assert_equal I18n.t("creatives.index.plan_tags_removed", default: "Plan tag removed from selected creatives."), flash[:notice]
  end

  test "removes plan tags from creatives via JSON" do
    @creative.tags.create!(label: @plan)

    delete creative_plan_path, params: { plan_id: @plan.id, creative_ids: @creative.id }, as: :json

    assert_response :ok
    json_response = JSON.parse(response.body)
    assert_equal I18n.t("creatives.index.plan_tags_removed", default: "Plan tag removed from selected creatives."), json_response["message"]
    assert_not @creative.tags.exists?(label: @plan)
  end

  test "returns alert when parameters are missing via HTML" do
    post creative_plan_path, params: { plan_id: nil, creative_ids: "" }

    assert_redirected_to creatives_path(select_mode: 1)
    assert_equal I18n.t("creatives.index.plan_tag_failed", default: "Please select a plan and at least one creative."), flash[:alert]
  end

  test "returns error when parameters are missing via JSON" do
    post creative_plan_path, params: { plan_id: nil, creative_ids: "" }, as: :json

    assert_response :unprocessable_entity
    json_response = JSON.parse(response.body)
    assert_equal I18n.t("creatives.index.plan_tag_failed", default: "Please select a plan and at least one creative."), json_response["error"]
  end
end
