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
end
