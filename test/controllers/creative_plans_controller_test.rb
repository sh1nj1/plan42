require "test_helper"

class CreativePlansControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = User.create!(email: "plan@example.com", password: "pw", name: "Planner", email_verified_at: Time.current)
    @plan = Plan.create!(name: "Launch", owner: @user, target_date: Date.today)
    @creative = Creative.create!(user: @user, description: "Root")
    sign_in_as(@user)
  end

  test "applies plan tags to creatives" do
    post creative_plan_path, params: { plan_id: @plan.id, creative_ids: @creative.id }

    assert_redirected_to creatives_path(select_mode: 1)
    assert_equal 1, @creative.tags.where(label: @plan).count
    assert_equal I18n.t("creatives.index.plan_tags_applied", default: "Plan tags applied to selected creatives."), flash[:notice]
  end

  test "removes plan tags from creatives" do
    @creative.tags.create!(label: @plan)

    delete creative_plan_path, params: { plan_id: @plan.id, creative_ids: @creative.id }

    assert_redirected_to creatives_path(select_mode: 1)
    assert_not @creative.tags.exists?(label: @plan)
    assert_equal I18n.t("creatives.index.plan_tags_removed", default: "Plan tag removed from selected creatives."), flash[:notice]
  end

  test "returns alert when parameters are missing" do
    post creative_plan_path, params: { plan_id: nil, creative_ids: "" }

    assert_redirected_to creatives_path(select_mode: 1)
    assert_equal I18n.t("creatives.index.plan_tag_failed", default: "Please select a plan and at least one creative."), flash[:alert]
  end
end
