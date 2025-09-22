require "test_helper"

class CreativeTest < ActiveSupport::TestCase
  # test "the truth" do
  #   assert true
  # end
  include ActionMailer::TestHelper

  test "sends email notifications when back in stock" do
    creative = creatives(:tshirt)

    # Set creative out of stock
    creative.update!(progress: 0.0)

    assert_emails 2 do
      creative.update(progress: 0.99)
    end
  end

  test "progress_for_tags averages tagged descendants" do
    user = users(:one)
    Current.session = OpenStruct.new(user: user)

    parent = Creative.create!(user: user, description: "Parent")
    Creative.create!(user: user, parent: parent, description: "Child 1", progress: 0.2)
    tagged_child1 = Creative.create!(user: user, parent: parent, description: "Child 2", progress: 0.8)
    tagged_child2 = Creative.create!(user: user, parent: parent, description: "Child 3", progress: 0.6)

    label = Label.create!(name: "Plan", owner: user)
    Tag.create!(creative_id: tagged_child1.id, label: label)
    Tag.create!(creative_id: tagged_child2.id, label: label)

    parent.reload

    assert_in_delta((0.2 + 0.8 + 0.6) / 3.0, parent.progress, 0.001)
    assert_in_delta((0.8 + 0.6) / 2.0,
                    parent.progress_for_tags([ label.id ], user),
                    0.001)

    Current.reset
  end

  test "progress_for_tags returns 1 when children filtered out" do
    user = users(:one)
    Current.session = OpenStruct.new(user: user)

    parent = Creative.create!(user: user, description: "Parent", progress: 0.2)
    Creative.create!(user: user, parent: parent, description: "Child", progress: 0.5)

    label = Label.create!(name: "Tag", owner: user)
    Tag.create!(creative_id: parent.id, label: label)

    assert_equal 1.0, parent.progress_for_tags([ label.id ], user)

    Current.reset
  end

  test "destroying creative removes comment read pointers" do
    user = users(:one)
    Current.session = OpenStruct.new(user: user)

    creative = Creative.create!(user: user, description: "Parent")
    Comment.create!(creative: creative, user: user, content: "hi")
    CommentReadPointer.create!(user: user, creative: creative)

    assert_difference("Creative.count", -1) do
      assert_nothing_raised { creative.destroy }
    end

    assert_empty CommentReadPointer.where(creative_id: creative.id)

    Current.reset
  end

  test "destroying creative removes expanded states" do
    user = users(:one)
    Current.session = OpenStruct.new(user: user)

    creative = Creative.create!(user: user, description: "Parent")
    CreativeExpandedState.create!(creative: creative, user: user, expanded_status: { "1" => true })

    assert_difference("Creative.count", -1) do
      assert_nothing_raised { creative.destroy }
    end

    assert_empty CreativeExpandedState.where(creative_id: creative.id)

    Current.reset
  end

  test "ids_with_permission skips descendants blocked by no access share" do
    Current.reset

    owner = users(:one)
    recipient = users(:two)

    parent = Creative.create!(user: owner, description: "Parent")
    child = Creative.create!(user: owner, parent: parent, description: "Child")

    CreativeShare.create!(creative: parent, user: recipient, permission: :write)
    CreativeShare.create!(creative: child, user: recipient, permission: :no_access)

    ids = Creative.ids_with_permission(recipient, :write)

    assert_includes ids, parent.id
    refute_includes ids, child.id

    Current.reset
  end
end
