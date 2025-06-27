require "test_helper"

class CreativeShareTest < ActiveSupport::TestCase
  test "creating a share notifies recipient" do
    creative = creatives(:tshirt)
    sharer = users(:one)
    recipient = users(:two)

    Current.session = OpenStruct.new(user: sharer)

    assert_difference("InboxItem.count", 1) do
      CreativeShare.create!(creative: creative, user: recipient, permission: :read)
    end

    item = InboxItem.last
    assert_equal recipient, item.owner
    assert_includes item.message, sharer.email
    assert_includes item.message, "T-Shirt"
    expected_link = Rails.application.routes.url_helpers.creative_url(
      creative,
      host: "example.com"
    )
    assert_equal expected_link, item.link

    Current.reset
  end
end
