require "test_helper"

class CommentReadTest < ActiveSupport::TestCase
  test "mark comment as read" do
    creative = creatives(:tshirt)
    commenter = users(:two)
    Comment.skip_callback(:commit, :after, :initialize_comment_reads, on: :create)
    comment = Comment.create!(creative: creative, user: commenter, content: "hi")
    comment.send(:initialize_comment_reads)
    Comment.set_callback(:commit, :after, :initialize_comment_reads, on: :create)
    owner = creative.user
    record = CommentRead.find_by(comment: comment, user: owner)
    assert_not record.read
    CommentRead.where(comment: comment, user: owner).update_all(read: true)
    assert CommentRead.find_by(comment: comment, user: owner).read
  end
end
