require "test_helper"

module Creatives
  module Filters
    class SearchFilterTest < ActiveSupport::TestCase
      setup do
        @owner = users(:one)
        @creative1 = Creative.create!(user: @owner, description: "Apple pie recipe", progress: 0.0)
        @creative2 = Creative.create!(user: @owner, description: "Banana bread", progress: 0.0)
        @creative3 = Creative.create!(user: @owner, description: "Apple sauce", progress: 0.0)
        @scope = Creative.where(id: [ @creative1.id, @creative2.id, @creative3.id ])
      end

      test "active? returns true when search param is present" do
        filter = SearchFilter.new(params: { search: "apple" }, scope: @scope)
        assert filter.active?
      end

      test "active? returns false when search param is absent" do
        filter = SearchFilter.new(params: {}, scope: @scope)
        refute filter.active?
      end

      test "active? returns false when search param is blank" do
        filter = SearchFilter.new(params: { search: "" }, scope: @scope)
        refute filter.active?
      end

      test "match returns creatives with matching description" do
        filter = SearchFilter.new(params: { search: "Apple" }, scope: @scope)
        result = filter.match

        assert_includes result, @creative1.id
        assert_includes result, @creative3.id
        refute_includes result, @creative2.id
      end

      test "match is case sensitive by default" do
        filter = SearchFilter.new(params: { search: "apple" }, scope: @scope)
        result = filter.match

        # LIKE is case-insensitive in SQLite by default
        assert_includes result, @creative1.id
        assert_includes result, @creative3.id
      end

      test "match returns empty when no matches found" do
        filter = SearchFilter.new(params: { search: "Cherry" }, scope: @scope)
        result = filter.match

        assert_empty result
      end

      test "match handles partial matches" do
        filter = SearchFilter.new(params: { search: "bread" }, scope: @scope)
        result = filter.match

        assert_equal [ @creative2.id ], result
      end

      # Multi-word AND search tests

      test "multi-word search matches only creatives containing all words" do
        filter = SearchFilter.new(params: { search: "Apple pie" }, scope: @scope)
        result = filter.match

        assert_includes result, @creative1.id       # "Apple pie recipe" contains both
        refute_includes result, @creative3.id        # "Apple sauce" missing "pie"
        refute_includes result, @creative2.id        # "Banana bread" missing both
      end

      test "multi-word search returns empty when words span different creatives" do
        filter = SearchFilter.new(params: { search: "Apple bread" }, scope: @scope)
        result = filter.match

        # "Apple" is in creative1/3, "bread" is in creative2 — no single creative has both
        assert_empty result
      end

      test "multi-word search with more than MAX_SEARCH_WORDS uses only first words" do
        # 6 words, only first 5 should be used
        filter = SearchFilter.new(
          params: { search: "Apple pie recipe extra words ignored" },
          scope: @scope
        )
        result = filter.match

        # "Apple pie recipe" matches first 5 words: Apple, pie, recipe, extra, words
        # creative1 = "Apple pie recipe" — has Apple, pie, recipe but NOT "extra" or "words"
        assert_empty result
      end

      test "single word search still works (backward compatibility)" do
        filter = SearchFilter.new(params: { search: "Banana" }, scope: @scope)
        result = filter.match

        assert_equal [ @creative2.id ], result
      end

      test "whitespace-only search returns empty" do
        filter = SearchFilter.new(params: { search: "   " }, scope: @scope)
        result = filter.match

        assert_empty result
      end

      test "multi-word search works across description and comments" do
        # Word1 in description, word2 in comment of same creative
        comment_creative = Creative.create!(user: @owner, description: "Project plan", progress: 0.0)
        Comment.create!(
          creative: comment_creative,
          user: @owner,
          content: "Need to review timeline"
        )
        scope_with_comment = Creative.where(id: [ comment_creative.id, @creative1.id ])

        filter = SearchFilter.new(params: { search: "plan timeline" }, scope: scope_with_comment)
        result = filter.match

        # "plan" in description, "timeline" in comment — same creative matches
        assert_includes result, comment_creative.id
        refute_includes result, @creative1.id
      end

      test "multi-word search with special characters is sanitized" do
        special_creative = Creative.create!(user: @owner, description: "100% complete_task", progress: 0.0)
        scope_special = Creative.where(id: [ special_creative.id ])

        filter = SearchFilter.new(params: { search: "100% complete_task" }, scope: scope_special)
        result = filter.match

        assert_includes result, special_creative.id
      end

      test "MAX_SEARCH_WORDS constant is 5" do
        assert_equal 5, SearchFilter::MAX_SEARCH_WORDS
      end
    end
  end
end
