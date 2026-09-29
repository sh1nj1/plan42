require "test_helper"

class OnboardingDestinationRedirectTest < ActionDispatch::IntegrationTest
  test "agent CTA preserves Main through redirect despite a different saved topic" do
    user = users(:one)
    sign_in_as(user, password: "password")
    inbox = user.inbox_creative
    other = inbox.topics.create!(name: "Other", user: user)
    Collavre::UserCreativePreference.create!(user: user, creative: inbox, last_topic_id: other.id)
    routes = Collavre::Engine.routes.url_helpers
    mission = Collavre::NoticeRegistry.find(:onboarding_call_agent)

    get mission.cta_path(routes, user)

    assert_redirected_to routes.creatives_path(id: inbox.id, open_comments: true, topic_id: inbox.main_topic.id)
    follow_redirect!
    assert_response :success
    assert_equal inbox.main_topic.id.to_s, request.params[:topic_id]
  end
end
