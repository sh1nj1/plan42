require "test_helper"

class InboxAccessTest < ActionDispatch::IntegrationTest
  test "unauthenticated inbox request does not store return location" do
    get collavre.inbox_items_path
    assert_redirected_to new_session_path
    assert_nil session[:return_to_after_authenticating]
  end
end
