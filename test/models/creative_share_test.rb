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
    expected_link = Rails.application.routes.url_helpers.creative_path(creative)
    assert_equal expected_link, item.link

    Current.reset
  end

  test "ancestor list ignores none permission" do
    owner = users(:one)
    recipient = users(:two)
    parent = Creative.create!(user: owner, description: "Parent")
    child = Creative.create!(user: owner, parent: parent, description: "Child")

    CreativeShare.create!(creative: parent, user: recipient, permission: :read)
    CreativeShare.create!(creative: child, user: recipient, permission: :none)

    ancestor_ids = [ child.id ] + child.ancestors.pluck(:id)
    list = CreativeShare
      .where(creative_id: ancestor_ids)
      .where.not(permission: :none)

    assert_equal 1, list.count
    assert_equal parent.id, list.first.creative_id
  end
end
