require "test_helper"

class CommentReadPointerTest < ActiveSupport::TestCase
  test "enforces uniqueness of user and creative" do
    user = User.create!(email: "read-pointer@example.com", password: "secret", name: "Reader")
    creative = Creative.create!(user: user, description: "Creative")
    CommentReadPointer.create!(user: user, creative: creative)

    duplicate = CommentReadPointer.new(user: user, creative: creative)

    refute duplicate.valid?
  end
end
