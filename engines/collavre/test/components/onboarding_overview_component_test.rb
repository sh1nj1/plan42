require "test_helper"

class OnboardingOverviewComponentTest < ViewComponent::TestCase
  setup do
    @user = users(:one)
    @user.update!(onboarding_seeded_at: nil, onboarding_completed_at: nil)
    Collavre::Creative.onboarding_guides.where(user: @user).destroy_all
    Collavre::Creative.inbox_for(@user)
    @root = Collavre::Onboarding::Seeder.call(user: @user)
    Current.user = @user
  end

  teardown do
    Current.user = nil
  end

  test "shows completed card count and skip action before all steps finish" do
    render_inline(Collavre::OnboardingOverviewComponent.new(creative: @root))

    assert_selector ".onboarding-overview-progress", text: "0/4"
    assert_selector "a[data-turbo-method='delete']",
                    text: I18n.t("collavre.onboarding.overview.skip")
    assert_selector "a.feature-card-guide-link[href='/features']"
  end

  test "shows finish action when all card states are completed" do
    @root.children.each do |card|
      data = card.data.deep_dup
      data["onboarding"]["status"] = "completed"
      card.update!(data: data)
    end

    render_inline(Collavre::OnboardingOverviewComponent.new(creative: @root))

    assert_selector ".onboarding-overview-progress", text: "4/4"
    assert_selector "a", text: I18n.t("collavre.onboarding.overview.finish")
  end

  test "hides completion actions from a non-owner" do
    Current.user = users(:two)

    render_inline(Collavre::OnboardingOverviewComponent.new(creative: @root))

    assert_no_selector "a[data-turbo-method='delete']"
    assert_selector "a.feature-card-guide-link"
  end
end
