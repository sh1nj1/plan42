require_relative "../application_system_test_case"

# The cron badge sits inside the topic chip, whose text color flips when the
# chip is selected. Pinning the badge to --text-muted left the count at ~1.1:1
# against the selected chip's accent fill — invisible in dark mode.
class TopicCronBadgeThemeTest < ApplicationSystemTestCase
  setup do
    @user = User.create!(
      email: "cron-badge-theme@example.com",
      password: SystemHelpers::PASSWORD,
      name: "CronBadgeThemeUser",
      email_verified_at: Time.current,
      notifications_enabled: false,
      theme: "dark"
    )
    @creative = Creative.create!(description: "Scheduled root", user: @user)
    @topic = Collavre::Topic.create!(name: "Alpha", creative: @creative, user: @user)
    @task = SolidQueue::RecurringTask.create!(
      key: "cron_#{@creative.id}_theme",
      class_name: "Collavre::CronActionJob",
      schedule: "0 9 * * *",
      static: false,
      arguments: [ { creative_id: @creative.id, topic_id: @topic.id, message: "Daily summary" } ]
    )

    resize_window_to
    sign_in_via_ui(@user)
  end

  teardown do
    @task.destroy! if @task&.persisted?
  end

  test "badge count uses the topic label color in dark mode, selected or not" do
    open_comments_popup

    assert_includes page.evaluate_script("document.body.className").split, "dark-mode"

    assert_equal(*chip_and_badge_color(".topic-tag:not(.active)"),
                 "idle topic chip badge must read like its label")

    # Click the chip itself, not its centre — the badge and the archive/delete
    # buttons sit there and swallow the selection click.
    select_topic_chip("Alpha")
    assert_selector "#comment-topics .topic-tag.active .creative-cron-badge", wait: 5

    assert_equal(*chip_and_badge_color(".topic-tag.active"),
                 "selected topic chip badge must read like its label")
  end

  private

  def select_topic_chip(name)
    chip = find("#comment-topics .topic-tag", text: name)
    page.execute_script("arguments[0].click()", chip)
  end

  def open_comments_popup
    visit root_path
    assert_selector "#creative-#{@creative.id}", wait: 5
    find("#creative-#{@creative.id}").hover
    within("#creative-#{@creative.id}") { find(".comments-btn").click }
    assert_selector "#comments-popup", wait: 5
    assert_selector "#comment-topics .topic-tag .creative-cron-badge", wait: 10
    assert_docked_comments_loaded
  end

  # Returns [chip label color, badge color] for the first chip matching
  # +chip_selector+ that actually carries a cron badge.
  def chip_and_badge_color(chip_selector)
    colors = page.evaluate_script(<<~JS)
      (() => {
        const chip = Array.from(
          document.querySelectorAll('#comment-topics #{chip_selector}')
        ).find(node => node.querySelector('.creative-cron-badge'))
        if (!chip) return null
        return [
          getComputedStyle(chip).color,
          getComputedStyle(chip.querySelector('.creative-cron-badge')).color
        ]
      })()
    JS
    assert colors, "no topic chip matching #{chip_selector} carries a cron badge"
    colors
  end
end
