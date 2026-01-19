require "test_helper"

module Creatives
  module Filters
    class AssigneeFilterTest < ActiveSupport::TestCase
      setup do
        @owner = users(:one)
        @other_user = users(:two)

        @creative1 = Creative.create!(user: @owner, description: "Creative 1", progress: 0.0)
        @creative2 = Creative.create!(user: @owner, description: "Creative 2", progress: 0.0)
        @creative3 = Creative.create!(user: @owner, description: "Creative 3", progress: 0.0)

        # Create a separate creative for labels
        @label_creative = Creative.create!(user: @owner, description: "Label Creative", progress: 0.0)

        # Create labels with different owners
        @label1 = Label.create!(creative: @label_creative, value: "Assigned to Owner", owner: @owner)
        @label2 = Label.create!(creative: @label_creative, value: "Assigned to Other", owner: @other_user)
        @label3 = Label.create!(creative: @label_creative, value: "Unassigned", owner: nil)

        # Assign tags to creatives
        Tag.create!(creative_id: @creative1.id, label: @label1)
        Tag.create!(creative_id: @creative2.id, label: @label2)
        # creative3 has no tags

        @scope = Creative.where(id: [ @creative1.id, @creative2.id, @creative3.id ])
      end

      test "active? returns true when assignee_id param is present" do
        filter = AssigneeFilter.new(params: { assignee_id: @owner.id }, scope: @scope)
        assert filter.active?
      end

      test "active? returns true when unassigned param is present" do
        filter = AssigneeFilter.new(params: { unassigned: "true" }, scope: @scope)
        assert filter.active?
      end

      test "active? returns false when params are absent" do
        filter = AssigneeFilter.new(params: {}, scope: @scope)
        refute filter.active?
      end

      test "match returns creatives assigned to specific user" do
        filter = AssigneeFilter.new(params: { assignee_id: @owner.id }, scope: @scope)
        result = filter.match

        assert_includes result, @creative1.id
        refute_includes result, @creative2.id
        refute_includes result, @creative3.id
      end

      test "match returns creatives assigned to other user" do
        filter = AssigneeFilter.new(params: { assignee_id: @other_user.id }, scope: @scope)
        result = filter.match

        refute_includes result, @creative1.id
        assert_includes result, @creative2.id
        refute_includes result, @creative3.id
      end

      test "match handles array of assignee_ids" do
        filter = AssigneeFilter.new(
          params: { assignee_id: [ @owner.id, @other_user.id ] },
          scope: @scope
        )
        result = filter.match

        assert_includes result, @creative1.id
        assert_includes result, @creative2.id
        refute_includes result, @creative3.id
      end

      test "match returns unassigned creatives when unassigned is true" do
        filter = AssigneeFilter.new(params: { unassigned: "true" }, scope: @scope)
        result = filter.match

        # creative3 has no tags, so it counts as unassigned
        assert_includes result, @creative3.id
      end

      test "match handles string assignee_id" do
        filter = AssigneeFilter.new(params: { assignee_id: @owner.id.to_s }, scope: @scope)
        result = filter.match

        assert_includes result, @creative1.id
      end
    end
  end
end
