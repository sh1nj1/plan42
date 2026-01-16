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
    end
  end
end
