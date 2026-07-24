# frozen_string_literal: true

require_relative "../application_system_test_case"

class TriggerTaskStatusTest < ApplicationSystemTestCase
  setup do
    @user = User.create!(
      email: "trigger-test@example.com",
      password: SystemHelpers::PASSWORD,
      name: "TriggerUser",
      email_verified_at: Time.current,
      notifications_enabled: false
    )

    @container = Collavre::Creative.create!(
      user: @user,
      description: "Trigger Container",
      data: { "trigger" => { "on_child_enter" => true } }
    )

    @task = Collavre::Creative.create!(
      user: @user,
      parent: @container,
      description: "Trigger Task Idle"
    )

    sign_in_via_ui(@user)
  end

  test "trigger task shows zap button with Idle tooltip in popup" do
    visit collavre.creatives_path(id: @container.id)

    # Wait for tree to load with the task
    assert_selector "button[name='show-comments-btn'][data-creative-id='#{@task.id}']", wait: 10

    # Click to open popup
    find("button[name='show-comments-btn'][data-creative-id='#{@task.id}']").click

    # Wait for popup
    assert_selector "#comments-popup", wait: 5

    # The trigger button should become visible
    trigger_btn = find("[data-comments--drop-trigger-target='triggerButton']", wait: 10)

    # Wait for async _loadTriggerState to complete and update UI
    # The button should not be hidden (display:none)
    assert_eventually(timeout: 10) do
      trigger_btn.evaluate_script("this.style.display") != "none"
    end

    # Verify tooltip
    assert_match(/Idle/i, trigger_btn["title"])
  end

  private

  def assert_eventually(timeout: 5, interval: 0.2)
    deadline = Time.now + timeout
    loop do
      return if yield
      raise "Assertion did not pass within #{timeout}s" if Time.now > deadline

      sleep interval
    end
  end
end
