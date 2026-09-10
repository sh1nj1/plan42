require_relative "../application_system_test_case"

class CreativeCronBadgeAlignmentTest < ApplicationSystemTestCase
  setup do
    @user = User.create!(
      email: "cron-badge-alignment@example.com",
      password: SystemHelpers::PASSWORD,
      name: "CronBadgeAlignmentUser",
      email_verified_at: Time.current,
      notifications_enabled: false
    )
    @creative = Creative.create!(description: "Scheduled creative", user: @user)
    @task = SolidQueue::RecurringTask.create!(
      key: "cron_#{@creative.id}_alignment",
      class_name: "Collavre::CronActionJob",
      schedule: "0 9 * * *",
      static: false,
      arguments: []
    )

    resize_window_to
    sign_in_via_ui(@user)
  end

  teardown do
    @task.destroy! if @task&.persisted?
  end

  test "cron badge aligns vertically with the progress checkbox" do
    visit collavre.creatives_path(has_cron: "true")
    row_selector = "#creative-#{@creative.id}"
    assert_selector "#{row_selector} .progress-toggle-checkbox", visible: :all
    assert_selector "#{row_selector} .creative-cron-badge", visible: :all

    positions = page.evaluate_script(<<~JS)
      (() => {
        const centerY = (selector) => {
          const rect = document.querySelector(selector).getBoundingClientRect()
          return rect.top + rect.height / 2
        }
        return {
          checkbox: centerY('#{row_selector} .progress-toggle-checkbox'),
          badge: centerY('#{row_selector} .creative-cron-badge')
        }
      })()
    JS

    assert_in_delta positions.fetch("checkbox"), positions.fetch("badge"), 1
  end

  test "edits the scheduled message from the cron badge popup" do
    visit collavre.creatives_path(has_cron: "true")
    row_selector = "#creative-#{@creative.id}"

    find("#{row_selector} .creative-cron-badge").click
    find("#{row_selector} .cron-task-message-input").set("Updated scheduled message")
    find("#{row_selector} .cron-task-save").click

    assert_selector "#{row_selector} .cron-task-message-input[data-cron-saved-message='Updated scheduled message']", visible: :all
    assert_equal "Updated scheduled message", @task.class.find(@task.id).arguments.first.stringify_keys.fetch("message")
  end
end
