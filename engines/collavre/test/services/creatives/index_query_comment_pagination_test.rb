require "test_helper"

module Creatives
  # The top-nav "Chats" list is the comment filter (?comment=true). It must be
  # paginated (newest chat first) and must never run a per-row permission check
  # or a per-row MAX(comments.updated_at) aggregate.
  class IndexQueryCommentPaginationTest < ActiveSupport::TestCase
    setup do
      @user = users(:one)

      # Four commented creatives, with comments timestamped oldest -> newest so
      # the expected recency order is c4, c3, c2, c1.
      @c1 = create_commented("Chat 1", 4.hours.ago)
      @c2 = create_commented("Chat 2", 3.hours.ago)
      @c3 = create_commented("Chat 3", 2.hours.ago)
      @c4 = create_commented("Chat 4", 1.hour.ago)

      # A creative without comments must never appear in the feed.
      @no_comment = Creative.create!(user: @user, description: "No chat", progress: 0.0)
    end

    test "first page returns one page ordered by most-recent comment with has_more" do
      result = IndexQuery.new(user: @user, params: { comment: "true", per_page: 2 }).call

      assert_equal [ @c4, @c3 ], result.creatives
      assert result.pagination[:has_more]
      assert_equal 2, result.pagination[:next_page]
      assert_equal 1, result.pagination[:page]
    end

    test "second page returns the next slice and reports no further pages" do
      result = IndexQuery.new(user: @user, params: { comment: "true", per_page: 2, page: 2 }).call

      assert_equal [ @c2, @c1 ], result.creatives
      refute result.pagination[:has_more]
      assert_nil result.pagination[:next_page]
    end

    test "feed excludes creatives the user cannot read" do
      other = users(:two)
      private_chat = Creative.create!(user: other, description: "Private chat", progress: 0.0)
      Comment.create!(creative: private_chat, user: other, content: "secret")
        .update_column(:updated_at, Time.current)

      result = IndexQuery.new(user: @user, params: { comment: "true" }).call

      refute_includes result.creatives, private_chat
      assert_includes result.creatives, @c4
    end

    test "feed excludes creatives without comments" do
      result = IndexQuery.new(user: @user, params: { comment: "true" }).call

      refute_includes result.creatives, @no_comment
    end

    test "empty feed reports no further pages" do
      Comment.delete_all
      result = IndexQuery.new(user: @user, params: { comment: "true" }).call

      assert_empty result.creatives
      refute result.pagination[:has_more]
    end

    private

    def create_commented(description, commented_at)
      creative = Creative.create!(user: @user, description: description, progress: 0.0)
      Comment.create!(creative: creative, user: @user, content: "#{description} comment")
        .update_column(:updated_at, commented_at)
      creative
    end
  end
end
