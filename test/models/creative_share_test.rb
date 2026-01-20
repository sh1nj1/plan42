require "test_helper"

class CreativeShareTest < ActiveSupport::TestCase
  test "creating a share notifies recipient" do
    creative = creatives(:tshirt)
    sharer = users(:one)
    recipient = users(:two)

    Current.session = OpenStruct.new(user: sharer)

    assert_difference("InboxItem.count", 1) do
      perform_enqueued_jobs do
        CreativeShare.create!(creative: creative, user: recipient, permission: :read)
      end
    end

    item = InboxItem.last
    assert_equal recipient, item.owner
    assert_equal "inbox.creative_shared", item.message_key
    msg = item.localized_message
    assert_includes msg, sharer.name
    assert_includes msg, "T-Shirt"
    expected_link = Rails.application.routes.url_helpers.creative_url(
      creative,
      host: "example.com"
    )
    assert_equal expected_link, item.link

    Current.reset
  end

  test "descendant no_access share removes read permission" do
    owner = User.create!(email: "share-owner@example.com", password: TEST_PASSWORD, name: "Owner")
    shared_user = User.create!(email: "share-shared@example.com", password: TEST_PASSWORD, name: "Shared")
    Current.session = Struct.new(:user).new(owner)

    root = nil
    child = nil
    grandchild = nil

    perform_enqueued_jobs do
      root = Creative.create!(user: owner, description: "Root")
      child = Creative.create!(user: owner, parent: root, description: "Child")
      grandchild = Creative.create!(user: owner, parent: child, description: "Grandchild")

      CreativeShare.create!(creative: root, user: shared_user, permission: :read)
    end

    assert child.has_permission?(shared_user, :read)

    perform_enqueued_jobs do
      CreativeShare.create!(creative: child, user: shared_user, permission: :no_access)
    end

    refute child.has_permission?(shared_user, :read)
    refute grandchild.has_permission?(shared_user, :read)
  ensure
    Current.reset
  end
end
