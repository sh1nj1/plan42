require "test_helper"
require_relative "../support/notice_test_helpers"

# The layout replaces the old one-shot flash div with the notice bar zone.
class NoticeBarLayoutTest < ActionDispatch::IntegrationTest
  include NoticeTestHelpers

  test "signed-in pages carry the bar and the user's notices" do
    user = create_notice_user
    sign_in_as(user)

    get collavre.creatives_path

    assert_response :success
    assert_select ".notice-zone[data-controller='notice-bar'][data-notice-bar-url-value='/user_notices/__key__']"
    assert_select "#notice-bar-payload[hidden]" do |payload|
      keys = JSON.parse(payload.first["data-items"]).map { |item| item["key"] }
      assert_equal %w[onboarding_first_creative], keys
    end
    assert_select "div.notice", count: 0
  end

  test "the flash notice renders as a toast" do
    sign_in_as(users(:one), password: "password")

    delete collavre.contact_path(contacts(:one_two))
    follow_redirect!

    assert_select ".notice-toast[data-notice-bar-target='flash']", text: I18n.t("collavre.contacts.notices.removed")
  end
end
