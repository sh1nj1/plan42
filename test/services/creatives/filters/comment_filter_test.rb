require "test_helper"

module Creatives
  module Filters
    class CommentFilterTest < ActiveSupport::TestCase
      setup do
        @owner = users(:one)
        @creative1 = Creative.create!(user: @owner, description: "Creative 1", progress: 0.0)
        @creative2 = Creative.create!(user: @owner, description: "Creative 2", progress: 0.0)
        @creative3 = Creative.create!(user: @owner, description: "Creative 3", progress: 0.0)

        # Add comments to creative1 and creative2
        Comment.create!(creative: @creative1, user: @owner, content: "Comment 1")
        Comment.create!(creative: @creative2, user: @owner, content: "Comment 2")

        @scope = Creative.where(id: [ @creative1.id, @creative2.id, @creative3.id ])
      end

      test "active? returns true when has_comments param is present" do
        filter = CommentFilter.new(params: { has_comments: "true" }, scope: @scope)
        assert filter.active?
      end

      test "active? returns true when comment param is present" do
        filter = CommentFilter.new(params: { comment: "true" }, scope: @scope)
        assert filter.active?
      end

      test "active? returns false when params are absent" do
        filter = CommentFilter.new(params: {}, scope: @scope)
        refute filter.active?
      end

      test "match returns creatives with comments when has_comments is true" do
        filter = CommentFilter.new(params: { has_comments: "true" }, scope: @scope)
        result = filter.match

        assert_includes result, @creative1.id
        assert_includes result, @creative2.id
        refute_includes result, @creative3.id
      end

      test "match returns creatives with comments when comment is true" do
        filter = CommentFilter.new(params: { comment: "true" }, scope: @scope)
        result = filter.match

        assert_includes result, @creative1.id
        assert_includes result, @creative2.id
        refute_includes result, @creative3.id
      end

      test "match returns creatives without comments when has_comments is false" do
        filter = CommentFilter.new(params: { has_comments: "false" }, scope: @scope)
        result = filter.match

        refute_includes result, @creative1.id
        refute_includes result, @creative2.id
        assert_includes result, @creative3.id
      end
    end
  end
end
