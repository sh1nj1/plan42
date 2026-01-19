require "test_helper"

module Creatives
  module Filters
    class TagFilterTest < ActiveSupport::TestCase
      setup do
        @owner = users(:one)
        @creative1 = Creative.create!(user: @owner, description: "Creative 1", progress: 0.0)
        @creative2 = Creative.create!(user: @owner, description: "Creative 2", progress: 0.0)
        @creative3 = Creative.create!(user: @owner, description: "Creative 3", progress: 0.0)

        @label = Label.create!(creative: @creative1, value: "Priority")
        @tag1 = Tag.create!(creative_id: @creative1.id, label: @label)
        @tag2 = Tag.create!(creative_id: @creative2.id, label: @label)

        @scope = Creative.where(id: [ @creative1.id, @creative2.id, @creative3.id ])
      end

      test "active? returns true when tags param is present" do
        filter = TagFilter.new(params: { tags: [ @label.id ] }, scope: @scope)
        assert filter.active?
      end

      test "active? returns false when tags param is absent" do
        filter = TagFilter.new(params: {}, scope: @scope)
        refute filter.active?
      end

      test "active? returns false when tags param is empty" do
        filter = TagFilter.new(params: { tags: [] }, scope: @scope)
        refute filter.active?
      end

      test "match returns creatives with matching tags" do
        filter = TagFilter.new(params: { tags: [ @label.id ] }, scope: @scope)
        result = filter.match

        assert_includes result, @creative1.id
        assert_includes result, @creative2.id
        refute_includes result, @creative3.id
      end

      test "match handles string tag ids" do
        filter = TagFilter.new(params: { tags: [ @label.id.to_s ] }, scope: @scope)
        result = filter.match

        assert_includes result, @creative1.id
        assert_includes result, @creative2.id
      end

      test "match returns empty when no creatives have matching tags" do
        # Create a label on a creative NOT in our scope
        other_creative = Creative.create!(user: @owner, description: "Other Creative", progress: 0.0)
        other_label = Label.create!(creative: other_creative, value: "Other")
        filter = TagFilter.new(params: { tags: [ other_label.id ] }, scope: @scope)
        result = filter.match

        assert_empty result
      end
    end
  end
end
