require "test_helper"

class CreativeShareTest < ActiveSupport::TestCase
  test "creating a share notifies recipient" do
    creative = creatives(:tshirt)
    sharer = users(:one)
    recipient = users(:two)

    Current.session = OpenStruct.new(user: sharer)

    inbox = Collavre::Creative.inbox_for(recipient)
    inbox_before = inbox.comments.count

    perform_enqueued_jobs do
      CreativeShare.create!(creative: creative, user: recipient, permission: :read)
    end

    assert_equal inbox_before + 1, inbox.comments.reload.count
    inbox_comment = inbox.comments.order(:id).last
    assert_nil inbox_comment.user
    assert_includes inbox_comment.content, sharer.name

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
