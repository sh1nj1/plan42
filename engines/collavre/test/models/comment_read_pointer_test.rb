require "test_helper"

class CommentReadPointerTest < ActiveSupport::TestCase
  test "enforces uniqueness of user and creative" do
    user = User.create!(email: "read-pointer@example.com", password: TEST_PASSWORD, name: "Reader")
    creative = Creative.create!(user: user, description: "Creative")
    CommentReadPointer.create!(user: user, creative: creative)

    duplicate = CommentReadPointer.new(user: user, creative: creative)

    refute duplicate.valid?
  end

  test "allows one pointer per topic on the same creative" do
    user = User.create!(email: "topic-read-pointer@example.com", password: TEST_PASSWORD, name: "Reader")
    creative = Creative.create!(user: user, description: "Creative")
    first_topic = creative.main_topic
    second_topic = creative.topics.create!(name: "Second", user: user)
    CommentReadPointer.create!(user: user, creative: creative, topic: first_topic)

    assert CommentReadPointer.new(user: user, creative: creative, topic: second_topic).valid?
  end
end
