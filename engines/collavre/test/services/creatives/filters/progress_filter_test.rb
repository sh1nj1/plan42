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

      test "active? returns true when min_progress param is present" do
        filter = ProgressFilter.new(params: { min_progress: "1" }, scope: @scope)
        assert filter.active?
      end

      test "active? returns true when max_progress param is present" do
        filter = ProgressFilter.new(params: { max_progress: "0.99" }, scope: @scope)
        assert filter.active?
      end

      test "active? returns false when no progress params" do
        filter = ProgressFilter.new(params: {}, scope: @scope)
        refute filter.active?
      end

      test "active? returns false when progress params are blank" do
        filter = ProgressFilter.new(params: { min_progress: "", max_progress: "" }, scope: @scope)
        refute filter.active?
      end

      test "match returns only completed creatives (min=1, max=1)" do
        filter = ProgressFilter.new(params: { min_progress: "1", max_progress: "1" }, scope: @scope)
        result = filter.match

        assert_includes result, @completed.id
        refute_includes result, @incomplete.id
        refute_includes result, @zero_progress.id
      end

      test "match returns only incomplete creatives (min=0, max=0.99)" do
        filter = ProgressFilter.new(params: { min_progress: "0", max_progress: "0.99" }, scope: @scope)
        result = filter.match

        refute_includes result, @completed.id
        assert_includes result, @incomplete.id
        assert_includes result, @zero_progress.id
      end

      test "match with only min_progress filters >= min" do
        filter = ProgressFilter.new(params: { min_progress: "0.5" }, scope: @scope)
        result = filter.match

        assert_includes result, @completed.id
        assert_includes result, @incomplete.id
        refute_includes result, @zero_progress.id
      end

      test "match with only max_progress filters <= max" do
        filter = ProgressFilter.new(params: { max_progress: "0.5" }, scope: @scope)
        result = filter.match

        refute_includes result, @completed.id
        assert_includes result, @incomplete.id
        assert_includes result, @zero_progress.id
      end

      test "match filters linked creatives by origin's progress" do
        # Origin with completed progress
        origin = Creative.create!(user: @owner, description: "Origin", progress: 1.0)
        # Linked creative (shell) - its own progress is 0, but should use origin's
        linked = Creative.create!(user: @owner, description: "Linked", origin: origin, parent: @completed)

        scope_with_linked = Creative.where(id: [ @completed.id, @incomplete.id, linked.id ])

        # Filter for completed (min=1, max=1)
        filter = ProgressFilter.new(params: { min_progress: "1", max_progress: "1" }, scope: scope_with_linked)
        result = filter.match

        assert_includes result, @completed.id
        assert_includes result, linked.id  # Should match because origin.progress = 1.0
        refute_includes result, @incomplete.id

        # Filter for incomplete (min=0, max=0.99)
        filter = ProgressFilter.new(params: { min_progress: "0", max_progress: "0.99" }, scope: scope_with_linked)
        result = filter.match

        refute_includes result, @completed.id
        refute_includes result, linked.id  # Should NOT match because origin.progress = 1.0
        assert_includes result, @incomplete.id
      end
    end
  end
end
