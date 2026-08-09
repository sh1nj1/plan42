require "test_helper"

class CreativesOnboardingTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:two)
    @user.update!(onboarding_seeded_at: nil, onboarding_completed_at: nil)
    Creative.onboarding_guides.where(user: @user).destroy_all
    Creative.inbox_for(@user)
    sign_in_as(@user, password: "password")
  end

  test "first root HTML visit seeds onboarding and opens the guide" do
    assert_difference -> { Creative.count }, 7 do
      get collavre.creatives_path
    end

    guide = Creative.onboarding_guides.find_by!(user: @user)
    assert_redirected_to collavre.creatives_path(id: guide.id)

    assert_no_difference -> { Creative.count } do
      follow_redirect!
    end
    assert_response :success
  end

  test "returning to the root does not seed onboarding again" do
    @user.update!(onboarding_seeded_at: Time.current)

    assert_no_difference -> { Creative.count } do
      get collavre.creatives_path
    end

    assert_response :success
  end

  test "direct creative visit does not seed onboarding" do
    creative = creatives(:root_parent)

    assert_no_difference -> { Creative.count } do
      get collavre.creatives_path(id: creative.id)
    end

    assert_response :success
    assert_nil @user.reload.onboarding_seeded_at
  end

  test "root JSON visit seeds onboarding without redirecting" do
    assert_difference -> { Creative.count }, 7 do
      get collavre.creatives_path(format: :json)
    end

    assert_response :success
    assert_not_nil @user.reload.onboarding_seeded_at
  end

  test "seeding failure does not block the workspace" do
    Collavre::Onboarding::Seeder.stub(:call, nil) do
      get collavre.creatives_path
    end

    assert_response :success
  end
end
