require "test_helper"

class CommentTest < ActiveSupport::TestCase
  test "creating a comment notifies creative owner" do
    creative = creatives(:tshirt)
    commenter = users(:two)

    comment = nil
    Comment.skip_callback(:commit, :after, :initialize_comment_reads, on: :create)
    assert_difference("InboxItem.count", 1) do
      comment = Comment.create!(creative: creative, user: commenter, content: "hi")
      comment.send(:initialize_comment_reads)
    end
    Comment.set_callback(:commit, :after, :initialize_comment_reads, on: :create)

    item = InboxItem.last
    assert_equal creative.user, item.owner
    assert_includes item.message, commenter.email
    expected_link = Rails.application.routes.url_helpers.creative_comment_url(
      creative,
      Comment.last,
      host: "example.com"
    )
    assert_equal expected_link, item.link
    read_for_owner = CommentRead.find_by(comment: comment, user: creative.user)
    assert_not read_for_owner.read
    read_for_commenter = CommentRead.find_by(comment: comment, user: commenter)
    assert read_for_commenter.read
  end
end
