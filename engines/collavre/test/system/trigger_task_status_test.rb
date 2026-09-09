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

    # The popup initializes with the preceding creative's state while its
    # trigger request is in flight. Wait for the task state instead of merely
    # waiting for the shared button to become visible.
    assert_selector "[data-comments--drop-trigger-target='triggerButton'][title*='Idle']", wait: 10
    assert_equal "Idle — click to start", trigger_btn["title"]
  end
end
