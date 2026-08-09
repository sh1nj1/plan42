require "test_helper"

class DestroyServiceOnboardingTest < ActiveSupport::TestCase
  setup do
    @user = users(:one)
    @user.update!(onboarding_seeded_at: Time.current, onboarding_completed_at: nil)
  end

  test "records completion after deleting an onboarding guide" do
    guide = Creative.create!(
      user: @user,
      description: "Onboarding",
      data: { "kind" => Creative::ONBOARDING_KIND }
    )

    Collavre::Creatives::DestroyService.new(creative: guide, user: @user, delete_with_children: true).call

    assert_not Creative.exists?(guide.id)
    assert_not_nil @user.reload.onboarding_completed_at
  end

  test "does not record completion after deleting ordinary content" do
    creative = Creative.create!(user: @user, description: "Ordinary")

    Collavre::Creatives::DestroyService.new(creative: creative, user: @user, delete_with_children: true).call

    assert_nil @user.reload.onboarding_completed_at
  end
end
