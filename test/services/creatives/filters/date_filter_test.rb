require "test_helper"

module Creatives
  module Filters
    class DateFilterTest < ActiveSupport::TestCase
      setup do
        @owner = users(:one)
        @creative1 = Creative.create!(user: @owner, description: "Creative 1", progress: 0.0)
        @creative2 = Creative.create!(user: @owner, description: "Creative 2", progress: 0.0)
        @creative3 = Creative.create!(user: @owner, description: "Creative 3", progress: 0.0)

        # Create a separate creative for labels to avoid auto-tag on scope creatives
        @label_creative = Creative.create!(user: @owner, description: "Label Creative", progress: 0.0)

        # Create labels with different target_dates
        @label1 = Label.create!(creative: @label_creative, value: "Due Soon", target_date: Date.today + 3.days)
        @label2 = Label.create!(creative: @label_creative, value: "Due Later", target_date: Date.today + 10.days)

        # Assign tags to creatives
        Tag.create!(creative_id: @creative1.id, label: @label1)
        Tag.create!(creative_id: @creative2.id, label: @label2)
        # creative3 has no tags/labels

        @scope = Creative.where(id: [ @creative1.id, @creative2.id, @creative3.id ])
      end

      test "active? returns true when due_before param is present" do
        filter = DateFilter.new(params: { due_before: (Date.today + 5.days).to_s }, scope: @scope)
        assert filter.active?
      end

      test "active? returns true when due_after param is present" do
        filter = DateFilter.new(params: { due_after: Date.today.to_s }, scope: @scope)
        assert filter.active?
      end

      test "active? returns true when has_due_date param is present" do
        filter = DateFilter.new(params: { has_due_date: "true" }, scope: @scope)
        assert filter.active?
      end

      test "active? returns false when params are absent" do
        filter = DateFilter.new(params: {}, scope: @scope)
        refute filter.active?
      end

      test "match returns creatives due before date" do
        filter = DateFilter.new(params: { due_before: (Date.today + 5.days).to_s }, scope: @scope)
        result = filter.match

        assert_includes result, @creative1.id
        refute_includes result, @creative2.id
        refute_includes result, @creative3.id
      end

      test "match returns creatives due after date" do
        filter = DateFilter.new(params: { due_after: (Date.today + 5.days).to_s }, scope: @scope)
        result = filter.match

        refute_includes result, @creative1.id
        assert_includes result, @creative2.id
        refute_includes result, @creative3.id
      end

      test "match returns creatives with due date when has_due_date is true" do
        filter = DateFilter.new(params: { has_due_date: "true" }, scope: @scope)
        result = filter.match

        assert_includes result, @creative1.id
        assert_includes result, @creative2.id
        refute_includes result, @creative3.id
      end

      test "match returns creatives without due date when has_due_date is false" do
        filter = DateFilter.new(params: { has_due_date: "false" }, scope: @scope)
        result = filter.match

        refute_includes result, @creative1.id
        refute_includes result, @creative2.id
        assert_includes result, @creative3.id
      end

      test "match combines due_before and due_after" do
        filter = DateFilter.new(
          params: {
            due_after: Date.today.to_s,
            due_before: (Date.today + 5.days).to_s
          },
          scope: @scope
        )
        result = filter.match

        assert_includes result, @creative1.id
        refute_includes result, @creative2.id
        refute_includes result, @creative3.id
      end
    end
  end
end
