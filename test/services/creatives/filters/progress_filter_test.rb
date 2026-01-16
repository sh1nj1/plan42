require "test_helper"

module Creatives
  module Filters
    class ProgressFilterTest < ActiveSupport::TestCase
      setup do
        @owner = users(:one)
        @completed = Creative.create!(user: @owner, description: "Completed", progress: 1.0)
        @incomplete = Creative.create!(user: @owner, description: "Incomplete", progress: 0.5)
        @zero_progress = Creative.create!(user: @owner, description: "Zero", progress: 0.0)
        @scope = Creative.where(id: [ @completed.id, @incomplete.id, @zero_progress.id ])
      end

      test "active? returns true when progress_filter param is present" do
        filter = ProgressFilter.new(params: { progress_filter: "completed" }, scope: @scope)
        assert filter.active?
      end

      test "active? returns false when progress_filter param is absent" do
        filter = ProgressFilter.new(params: {}, scope: @scope)
        refute filter.active?
      end

      test "active? returns false when progress_filter param is blank" do
        filter = ProgressFilter.new(params: { progress_filter: "" }, scope: @scope)
        refute filter.active?
      end

      test "match returns only completed creatives when completed filter" do
        filter = ProgressFilter.new(params: { progress_filter: "completed" }, scope: @scope)
        result = filter.match

        assert_includes result, @completed.id
        refute_includes result, @incomplete.id
        refute_includes result, @zero_progress.id
      end

      test "match returns only incomplete creatives when incomplete filter" do
        filter = ProgressFilter.new(params: { progress_filter: "incomplete" }, scope: @scope)
        result = filter.match

        refute_includes result, @completed.id
        assert_includes result, @incomplete.id
        assert_includes result, @zero_progress.id
      end

      test "match returns all creatives for unknown filter value" do
        filter = ProgressFilter.new(params: { progress_filter: "all" }, scope: @scope)
        result = filter.match

        assert_includes result, @completed.id
        assert_includes result, @incomplete.id
        assert_includes result, @zero_progress.id
      end
    end
  end
end
