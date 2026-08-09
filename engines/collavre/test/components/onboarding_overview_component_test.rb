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

    assert_selector ".onboarding-overview-progress", text: "0/3"
    assert_selector ".feature-card-description", text: "3 cards"
    assert_selector "a[data-turbo-method='delete']",
                    text: I18n.t("collavre.onboarding.overview.skip")
    assert_selector "a[data-turbo-confirm*='3 steps']"
    assert_selector "a.feature-card-guide-link[href='/features']"
  end

  test "shows finish action when all card states are completed" do
    @root.children.each do |card|
      data = card.data.deep_dup
      data["onboarding"]["status"] = "completed"
      card.update!(data: data)
    end

    render_inline(Collavre::OnboardingOverviewComponent.new(creative: @root))

    assert_selector ".onboarding-overview-progress", text: "3/3"
    assert_selector "a", text: I18n.t("collavre.onboarding.overview.finish")
  end

  test "hides completion actions from a non-owner" do
    Current.user = users(:two)

    render_inline(Collavre::OnboardingOverviewComponent.new(creative: @root))

    assert_no_selector "a[data-turbo-method='delete']"
    assert_selector "a.feature-card-guide-link"
  end

  test "includes the mention step in the total when an agent is available" do
    Collavre::Onboarding::Seeder.reset!(user: @user)
    users(:ai_bot).update!(created_by_id: @user.id)
    @root = Collavre::Onboarding::Seeder.call(user: @user)

    render_inline(Collavre::OnboardingOverviewComponent.new(creative: @root))

    assert_selector ".onboarding-overview-progress", text: "0/4"
    assert_selector ".feature-card-description", text: "4 cards"
    assert_selector "a[data-turbo-confirm*='4 steps']"
  end

  test "interpolates the Korean card count" do
    I18n.with_locale(:ko) do
      render_inline(Collavre::OnboardingOverviewComponent.new(creative: @root))
    end

    assert_selector ".feature-card-description", text: "카드 3개"
    assert_selector "a[data-turbo-confirm*='3단계']"
  end
end
