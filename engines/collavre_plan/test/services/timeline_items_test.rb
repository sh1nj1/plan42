require "test_helper"

class CollavrePlanTimelineItemsTest < ActiveSupport::TestCase
  test "plan without a creative falls back to the localized target date and the creatives index" do
    plan = Plan.new(id: 42, target_date: Date.new(2026, 1, 2), created_at: Time.zone.local(2026, 1, 1))

    item = CollavrePlan::TimelineItems.new.plan(plan)

    assert_equal I18n.l(Date.new(2026, 1, 2)), item[:name]
    assert_nil item[:start_date]
    assert_equal "/creatives?tags%5B%5D=42", item[:path]
  end

  test "blank creative id is ignored" do
    plan = Plan.new(id: 42, target_date: Date.new(2026, 1, 2), created_at: Time.zone.local(2026, 1, 1))

    assert_equal "/creatives?tags%5B%5D=42", CollavrePlan::TimelineItems.new(creative_id: "").plan(plan)[:path]
    assert_equal "/creatives/7?tags%5B%5D=42", CollavrePlan::TimelineItems.new(creative_id: "7").plan(plan)[:path]
  end
end
