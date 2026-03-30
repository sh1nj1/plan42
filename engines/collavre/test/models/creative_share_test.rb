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
    assert_equal recipient.id, item.owner.id
    assert_equal "inbox.creative_shared", item.message_key
    msg = item.localized_message
    assert_includes msg, sharer.name
    assert_includes msg, "T-Shirt"
    expected_link = Collavre::Engine.routes.url_helpers.creative_url(
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

  test "create broadcasts share change to comments presence channel" do
    creative = creatives(:tshirt)
    recipient = users(:two)

    broadcast_args = nil
    CommentsPresenceChannel.stub :broadcast_shares_changed, ->(*args, **kwargs) { broadcast_args = [ args, kwargs ] } do
      CreativeShare.create!(creative: creative, user: recipient, permission: :read)
    end

    assert_equal [ creative.effective_origin.id ], broadcast_args[0]
    assert_equal recipient.id, broadcast_args[1][:shared_user_id]
    assert_equal "read", broadcast_args[1][:permission]
    assert_equal "created", broadcast_args[1][:action]
  end

  test "update broadcasts share change to comments presence channel" do
    creative = creatives(:tshirt)
    recipient = users(:two)
    share = CreativeShare.create!(creative: creative, user: recipient, permission: :read)

    broadcasts = []
    CommentsPresenceChannel.stub :broadcast_shares_changed, ->(*args, **kwargs) { broadcasts << [ args, kwargs ] } do
      share.update!(permission: :feedback)
    end

    assert_equal [ creative.effective_origin.id ], broadcasts.last[0]
    assert_equal recipient.id, broadcasts.last[1][:shared_user_id]
    assert_equal "feedback", broadcasts.last[1][:permission]
    assert_equal "updated", broadcasts.last[1][:action]
  end

  test "destroy broadcasts share removal to comments presence channel" do
    creative = creatives(:tshirt)
    recipient = users(:two)
    share = CreativeShare.create!(creative: creative, user: recipient, permission: :read)

    broadcasts = []
    CommentsPresenceChannel.stub :broadcast_shares_changed, ->(*args, **kwargs) { broadcasts << [ args, kwargs ] } do
      share.destroy!
    end

    assert_equal [ creative.effective_origin.id ], broadcasts.last[0]
    assert_equal recipient.id, broadcasts.last[1][:shared_user_id]
    assert_nil broadcasts.last[1][:permission]
    assert_equal "destroyed", broadcasts.last[1][:action]
  end
end
