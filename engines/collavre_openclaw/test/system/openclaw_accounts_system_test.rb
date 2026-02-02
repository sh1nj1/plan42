# frozen_string_literal: true

require_relative "../application_system_test_case"

class OpenclawAccountsSystemTest < CollavreOpenclawSystemTestCase
  setup do
    @admin = User.create!(
      email: "openclaw-admin-#{SecureRandom.hex(4)}@example.com",
      password: SystemHelpers::PASSWORD,
      name: "Admin User",
      email_verified_at: Time.current,
      notifications_enabled: false,
      system_admin: true
    )

    @ai_user = User.create!(
      email: "test-ai-#{SecureRandom.hex(4)}@ai.collavre.local",
      password: SecureRandom.hex(32),
      name: "Test AI Agent",
      email_verified_at: Time.current,
      notifications_enabled: false,
      llm_vendor: "openclaw",
      llm_model: "default",
      created_by_id: @admin.id
    )

    resize_window_to
    sign_in_via_ui(@admin)
  end

  test "edit AI user page shows OpenClaw configuration section" do
    visit collavre.edit_ai_user_path(@ai_user)

    # Should see the OpenClaw configuration section
    assert_selector "h3", text: /OpenClaw/i
    # Should have link to configure gateway when not configured
    assert_selector "a", text: "Configure OpenClaw Gateway"
  end

  test "can navigate to new OpenClaw account page" do
    visit collavre.edit_ai_user_path(@ai_user)

    click_link "Configure OpenClaw Gateway"

    # Should be on new account page
    assert_selector "h1", text: I18n.t("collavre_openclaw.accounts.new_title")
  end

  test "new account form has proper structure" do
    visit collavre_openclaw.new_account_path(user_id: @ai_user.id)

    # Form should have profile-form class
    assert_selector "form.profile-form"

    # All required fields should be present
    assert_selector "label", text: I18n.t("collavre_openclaw.form.gateway_url")
    assert_selector "label", text: I18n.t("collavre_openclaw.form.api_token")
  end

  test "can create OpenClaw connection" do
    visit collavre_openclaw.new_account_path(user_id: @ai_user.id)

    fill_in I18n.t("collavre_openclaw.form.gateway_url"), with: "http://localhost:18789"

    click_button I18n.t("collavre_openclaw.form.submit_create")

    # Should redirect to AI user edit page with success message
    assert_current_path collavre.edit_ai_user_path(@ai_user), ignore_query: true
    assert_selector ".notice", text: I18n.t("collavre_openclaw.accounts.created")
  end

  test "edit page has action buttons in profile-actions section" do
    # Create account first
    account = CollavreOpenclaw::OpenclawAccount.create!(
      user: @ai_user,
      gateway_url: "http://localhost:18789",
      channel_id: "test-channel"
    )

    visit collavre_openclaw.edit_account_path(account)

    # Should have title
    assert_selector "h1", text: I18n.t("collavre_openclaw.accounts.edit_title")

    # Scroll to bottom to ensure profile-actions is visible
    page.execute_script("window.scrollTo(0, document.body.scrollHeight)")

    # Should have profile-actions div with buttons (button_to generates forms with input or button)
    assert_selector ".profile-actions", visible: :all
    within ".profile-actions", visible: :all do
      # button_to might generate <input type="submit"> or <button type="submit">
      assert_text I18n.t("collavre_openclaw.form.test_connection")
      assert_text I18n.t("collavre_openclaw.form.disconnect")
    end
  end

  test "test connection stays on edit page" do
    account = CollavreOpenclaw::OpenclawAccount.create!(
      user: @ai_user,
      gateway_url: "http://localhost:18789"
    )

    visit collavre_openclaw.edit_account_path(account)

    within ".profile-actions" do
      click_button I18n.t("collavre_openclaw.form.test_connection")
    end

    # Should stay on edit page (not redirect to /users)
    assert_current_path collavre_openclaw.edit_account_path(account), ignore_query: true
  end

  test "cancel link returns to AI user edit page" do
    visit collavre_openclaw.new_account_path(user_id: @ai_user.id)

    click_link I18n.t("collavre_openclaw.form.cancel")

    assert_current_path collavre.edit_ai_user_path(@ai_user), ignore_query: true
  end

  test "update button saves changes and redirects correctly" do
    account = CollavreOpenclaw::OpenclawAccount.create!(
      user: @ai_user,
      gateway_url: "http://localhost:18789",
      channel_id: "old-channel"
    )

    visit collavre_openclaw.edit_account_path(account)

    # Update fields (select all and replace)
    channel_field = find_field(I18n.t("collavre_openclaw.form.channel_id"))
    channel_field.native.clear
    channel_field.set("new-channel")

    # Submit form via JavaScript to bypass Turbo
    page.execute_script("document.querySelector('form.profile-form').submit()")
    
    # Wait for page to load
    sleep 2

    # Should redirect to AI user edit page with success message
    assert_current_path collavre.edit_ai_user_path(@ai_user), ignore_query: true
    assert_selector ".notice", text: I18n.t("collavre_openclaw.accounts.updated")

    # Verify changes were saved
    account.reload
    assert_equal "new-channel", account.channel_id
  end

  test "edit form shows existing values" do
    account = CollavreOpenclaw::OpenclawAccount.create!(
      user: @ai_user,
      gateway_url: "http://localhost:18789",
      channel_id: "existing-channel"
    )

    visit collavre_openclaw.edit_account_path(account)

    # Verify existing values are displayed in form
    assert_field I18n.t("collavre_openclaw.form.gateway_url"), with: "http://localhost:18789"
    assert_field I18n.t("collavre_openclaw.form.channel_id"), with: "existing-channel"
  end

  test "update with invalid data shows errors on same page" do
    account = CollavreOpenclaw::OpenclawAccount.create!(
      user: @ai_user,
      gateway_url: "http://localhost:18789"
    )

    visit collavre_openclaw.edit_account_path(account)

    # Clear required field
    fill_in I18n.t("collavre_openclaw.form.gateway_url"), with: ""

    click_button I18n.t("collavre_openclaw.form.submit_update")

    # Should stay on edit page (re-render with errors)
    assert_selector "h1", text: I18n.t("collavre_openclaw.accounts.edit_title")
  end

  test "update button works when token is configured" do
    account = CollavreOpenclaw::OpenclawAccount.create!(
      user: @ai_user,
      gateway_url: "http://localhost:18789",
      api_token: "existing-secret-token",
      channel_id: "old-channel"
    )

    visit collavre_openclaw.edit_account_path(account)

    # Verify token is shown as configured
    assert_selector ".token-status--configured"

    # Update channel_id field
    channel_field = find_field(I18n.t("collavre_openclaw.form.channel_id"))
    channel_field.native.clear
    channel_field.set("updated-channel")

    # Click update button
    click_button I18n.t("collavre_openclaw.form.submit_update")

    # Should redirect to AI user edit page with success message
    assert_current_path collavre.edit_ai_user_path(@ai_user), ignore_query: true
    assert_selector ".notice", text: I18n.t("collavre_openclaw.accounts.updated")

    # Verify changes were saved and token is preserved
    account.reload
    assert_equal "updated-channel", account.channel_id
    assert account.token_configured?, "Token should still be configured after update"
  end

  test "update button works when changing gateway url with token configured" do
    account = CollavreOpenclaw::OpenclawAccount.create!(
      user: @ai_user,
      gateway_url: "http://localhost:18789",
      api_token: "existing-secret-token"
    )

    visit collavre_openclaw.edit_account_path(account)

    # Update gateway URL
    gateway_field = find_field(I18n.t("collavre_openclaw.form.gateway_url"))
    gateway_field.native.clear
    gateway_field.set("http://new-gateway:18789")

    # Click update button
    click_button I18n.t("collavre_openclaw.form.submit_update")

    # Should redirect with success
    assert_current_path collavre.edit_ai_user_path(@ai_user), ignore_query: true
    assert_selector ".notice", text: I18n.t("collavre_openclaw.accounts.updated")

    # Verify changes
    account.reload
    assert_equal "http://new-gateway:18789", account.gateway_url
  end
end
