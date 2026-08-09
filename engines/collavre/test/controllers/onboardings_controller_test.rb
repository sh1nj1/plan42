require "test_helper"

class OnboardingsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:one)
    @user.update!(onboarding_seeded_at: nil, onboarding_completed_at: nil)
    Collavre::Creative.onboarding_guides.where(user: @user).destroy_all
    Collavre::Creative.inbox_for(@user)
    @root = Collavre::Onboarding::Seeder.call(user: @user)
    @session_id = @root.onboarding_metadata["session_id"]
    sign_in_as(@user, password: "password")
  end

  test "closing onboarding removes its durable session and redirects to the workspace" do
    delete collavre.onboarding_path

    assert_redirected_to collavre.creatives_path
    remaining = Collavre::Creative.where(user: @user).select do |creative|
      creative.onboarding_metadata&.dig("session_id") == @session_id
    end
    assert_empty remaining
    assert_not_nil @user.reload.onboarding_completed_at
  end

  test "closing when no active guide remains is harmless" do
    Collavre::Onboarding::CompletionService.call(user: @user, session_id: @session_id)

    assert_no_difference -> { Collavre::Creative.count } do
      delete collavre.onboarding_path
    end

    assert_redirected_to collavre.creatives_path
  end
end
