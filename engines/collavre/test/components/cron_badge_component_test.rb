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
    assert_selector "textarea.cron-task-message-input[data-cron-badge-target='messageInput'][data-cron-saved-message='Daily summary']", text: "Daily summary"
    assert_selector "time[datetime='#{time.iso8601}']"
    assert_selector "button.cron-task-save.btn.btn-primary.btn-sm[data-cron-update-url='/creatives/42/crons/cron_42_daily']", text: "Save"
    assert_selector "button.cron-task-delete.btn.btn-danger.btn-sm[data-cron-delete-url='/creatives/42/crons/cron_42_daily']"
  end

  test "renders the selected clock SVG as decoration inside the accessible badge" do
    task = Task.new("cron_42_daily", "0 9 * * *", nil, [])

    render_inline(Collavre::CronBadgeComponent.new(tasks: [ task ], creative_id: 42))

    assert_selector "button.creative-cron-badge[aria-label='1 scheduled job']" do
      assert_selector "svg[width='16'][height='16'][viewbox='0 0 24 24'][fill='none'][stroke='currentColor'][stroke-width='1.7'][aria-hidden='true'][focusable='false']" do
        assert_selector "circle[cx='12'][cy='12'][r='9']"
        assert_selector "path[d='M12 7v5l3 2']"
      end
    end
    assert_no_text "⏰"
  end

  test "renders unavailable values and omits deletion without write access" do
    task = Task.new("cron_42_daily", "0 9 * * *", nil, [])

    render_inline(
      Collavre::CronBadgeComponent.new(tasks: [ task ], creative_id: 42)
    )

    assert_text "Not available", count: 2
    assert_no_selector ".cron-task-message-input"
    assert_no_selector ".cron-task-save"
    assert_no_selector ".cron-task-delete"
  end

  test "preserves a leading newline in an editable message" do
    message = "\nDaily summary"
    task = Task.new("cron_42_daily", "0 9 * * *", nil, [ { message: message } ])

    render_inline(
      Collavre::CronBadgeComponent.new(
        tasks: [ task ],
        creative_id: 42,
        can_delete: true
      )
    )

    textarea = Capybara.string(rendered_content).find("textarea.cron-task-message-input")

    assert_equal message, textarea.value
    assert_equal message, textarea["data-cron-saved-message"]
  end

  test "renders the next run in the current user's time zone" do
    time = Time.utc(2026, 9, 5, 9)
    task = Task.new("cron_42_daily", "0 9 * * *", time, [ { message: "Daily summary" } ])

    Time.use_zone("Asia/Seoul") do
      render_inline(Collavre::CronBadgeComponent.new(tasks: [ task ], creative_id: 42))

      assert_selector "time[datetime='#{time.iso8601}']", text: "5 Sep 18:00"
    end
  end
end
