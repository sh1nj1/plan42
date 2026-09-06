# frozen_string_literal: true

require "test_helper"

class CronBadgeComponentTest < ViewComponent::TestCase
  Task = Struct.new(:key, :schedule, :next_time, :arguments)

  test "renders schedule, message, next run, and a deletion action" do
    time = Time.zone.parse("2026-09-05 09:00")
    task = Task.new("cron_42_daily", "0 9 * * *", time, [ { message: "Daily summary" } ])

    render_inline(
      Collavre::CronBadgeComponent.new(
        tasks: [ task ],
        creative_id: 42,
        can_delete: true
      )
    )

    assert_selector "[data-controller='popup-menu cron-badge']"
    assert_selector "[data-cron-badge-count-one-value='__count__ scheduled job']"
    assert_selector "button.creative-cron-badge[data-cron-badge-target='badge']", text: "1"
    assert_selector ".cron-task code", text: "0 9 * * *"
    assert_selector ".cron-task-message", text: "Daily summary"
    assert_selector "time[datetime='#{time.iso8601}']"
    assert_selector "button.cron-task-delete[data-cron-delete-url='/creatives/42/crons/cron_42_daily']"
  end

  test "renders unavailable values and omits deletion without write access" do
    task = Task.new("cron_42_daily", "0 9 * * *", nil, [])

    render_inline(
      Collavre::CronBadgeComponent.new(tasks: [ task ], creative_id: 42)
    )

    assert_text "Not available", count: 2
    assert_no_selector ".cron-task-delete"
  end
end
