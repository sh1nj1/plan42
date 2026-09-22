require "test_helper"

class BackgroundAuthenticationTest < ActionDispatch::IntegrationTest
  setup do
    creative = creatives(:tshirt)
    topic = creative.topics.create!(name: "Background request", user: users(:one))
    @background_path = collavre.channel_chips_creative_topic_url(creative, topic)
    @page_path = collavre.creative_topics_url(creative)
  end

  test "unauthenticated background request does not replace the post-login destination" do
    get @background_path, headers: { "HTTP_X_REQUESTED_WITH" => "XMLHttpRequest" }

    assert_response :unauthorized
    assert_nil session[:return_to_after_authenticating]
  end

  test "unauthenticated page navigation still stores the post-login destination" do
    get @page_path

    assert_redirected_to collavre.new_session_path
    assert_equal @page_path, session[:return_to_after_authenticating]
  end
end
