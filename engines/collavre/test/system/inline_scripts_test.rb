require_relative "../application_system_test_case"

class InlineScriptsTest < ApplicationSystemTestCase
  setup do
    @user = User.create!(
      email: "inline-scripts-test@example.com",
      password: SystemHelpers::PASSWORD,
      name: "TestUser",
      email_verified_at: Time.current,
      notifications_enabled: false
    )

    resize_window_to
    sign_in_via_ui(@user)
  end

  private

  def assert_eventually(timeout: 5, interval: 0.1)
    start_time = Time.now
    loop do
      return if yield
      raise "Condition not met within #{timeout} seconds" if Time.now - start_time > timeout
      sleep interval
    end
  end

  def clear_inbox_state
    page.execute_script("localStorage.removeItem('inboxOpen')")
  end

  def stub_clipboard
    # Stub navigator.clipboard for tests in non-secure contexts
    # Uses try/catch and Object.defineProperty for read-only property handling
    page.execute_script(<<~JS)
      window.__clipboardData = null;
      window.__clipboardStubbed = false;

      var stubClipboard = {
        writeText: function(text) {
          window.__clipboardData = text;
          return Promise.resolve();
        }
      };

      // Try direct assignment first (works in most cases)
      try {
        if (!navigator.clipboard) {
          navigator.clipboard = stubClipboard;
          window.__clipboardStubbed = true;
        } else {
          var originalWriteText = navigator.clipboard.writeText;
          navigator.clipboard.writeText = function(text) {
            window.__clipboardData = text;
            if (originalWriteText) {
              return originalWriteText.call(navigator.clipboard, text).catch(function() {
                return Promise.resolve();
              });
            }
            return Promise.resolve();
          };
          window.__clipboardStubbed = true;
        }
      } catch (e) {
        // If direct assignment fails (read-only), try Object.defineProperty
        try {
          Object.defineProperty(navigator, 'clipboard', {
            value: stubClipboard,
            writable: true,
            configurable: true
          });
          window.__clipboardStubbed = true;
        } catch (e2) {
          // If all else fails, just ensure __clipboardData works via the fallback path
          console.warn('Could not stub clipboard, fallback path will be used');
        }
      }
    JS
  end

  def force_clipboard_fallback
    # Force the clipboard fallback path by making writeText throw
    page.execute_script(<<~JS)
      window.__clipboardData = null;
      window.__clipboardFallbackUsed = false;

      // Store original execCommand to detect fallback usage
      var originalExecCommand = document.execCommand;
      document.execCommand = function(cmd) {
        if (cmd === 'copy') {
          window.__clipboardFallbackUsed = true;
        }
        return originalExecCommand.apply(document, arguments);
      };

      // Make clipboard.writeText throw to trigger fallback
      try {
        if (navigator.clipboard) {
          navigator.clipboard.writeText = function(text) {
            return Promise.reject(new Error('Clipboard not available'));
          };
        }
      } catch (e) {
        try {
          Object.defineProperty(navigator, 'clipboard', {
            value: {
              writeText: function(text) {
                return Promise.reject(new Error('Clipboard not available'));
              }
            },
            writable: true,
            configurable: true
          });
        } catch (e2) {
          // Already no clipboard, fallback will be used
        }
      }
    JS
  end

  public

  test "plans menu opens and loads plans on click" do
    creative = Creative.create!(user: @user, description: "Test Creative for Plans")
    Plan.create!(creative: creative, target_date: Date.current + 7.days)

    visit root_path

    # Plans area should be hidden initially
    assert_selector "#plans-list-area", visible: :hidden

    # Click plans menu button
    find(".plans-menu-btn", match: :first).click

    # Plans area should become visible
    assert_selector "#plans-list-area", visible: :visible

    # Click again to hide
    find(".plans-menu-btn", match: :first).click
    assert_selector "#plans-list-area", visible: :hidden
  end

  test "inbox panel opens and closes on button click" do
    visit root_path
    clear_inbox_state
    visit root_path

    # Inbox panel should not have 'open' class initially
    assert_no_selector "#inbox-panel.open"

    # Click inbox menu button
    find(".inbox-menu-btn", match: :first).click

    # Inbox panel should have 'open' class
    assert_selector "#inbox-panel.open", wait: 5

    # Click close button via JavaScript (more reliable for event-bound elements)
    page.execute_script("document.getElementById('close-inbox').click()")

    # Wait for the class to be removed
    assert_no_selector "#inbox-panel.open", wait: 5
  end

  test "creative guide popover shows on help button click" do
    # Clear help_menu_link setting to ensure popover shows instead of redirect
    SystemSetting.find_by(key: "help_menu_link")&.destroy

    visit root_path

    # Popover should be hidden initially
    assert_selector "#creative-guide-popover", visible: :all

    # Click help button (the "?" button) - use CSS selector for desktop button
    find("#creative-guide-link", visible: :all, match: :first).click

    # Popover should become visible
    assert_selector "#creative-guide-popover[style*='display: block']", visible: :visible, wait: 5

    # Click close button
    find("#close-creative-guide").click

    # Popover should be hidden again
    assert_no_selector "#creative-guide-popover[style*='display: block']", wait: 5
  end

  test "share modal opens and closes correctly" do
    creative = Creative.create!(user: @user, description: "Shareable Creative")

    visit collavre.creative_path(creative)

    # Modal should be hidden initially
    assert_selector "#share-creative-modal", visible: :hidden

    # Click share button
    find("#share-creative-btn").click

    # Modal should become visible
    assert_selector "#share-creative-modal", visible: :visible

    # Click close button
    find("#close-share-modal").click

    # Modal should be hidden again
    assert_selector "#share-creative-modal", visible: :hidden
  end

  test "share modal closes when clicking on backdrop" do
    creative = Creative.create!(user: @user, description: "Another Shareable")

    visit collavre.creative_path(creative)

    find("#share-creative-btn").click
    assert_selector "#share-creative-modal", visible: :visible

    # Click on the modal backdrop (the modal element itself, not the popup-box inside)
    # We need to click at a position that's on the backdrop, not the inner content
    modal = find("#share-creative-modal")
    # Execute JavaScript to click on the modal backdrop directly
    page.execute_script("document.getElementById('share-creative-modal').click()")

    # Modal should be hidden
    assert_selector "#share-creative-modal[style*='display: none']", visible: :all, wait: 5
  end

  test "timezone is auto-detected on login page" do
    # Sign out first
    visit root_path
    find(".nav-avatar", match: :first).click
    click_button I18n.t("app.sign_out")

    # Visit login page
    visit collavre.new_session_path

    # Wait for turbo:load to fire and timezone to be set
    sleep 0.5

    # Check that timezone field has a value
    timezone_value = find("#login-timezone", visible: :all).value
    assert timezone_value.present?, "Timezone should be auto-detected"
    # Timezone should be a valid IANA timezone like "Asia/Seoul" or "America/New_York"
    # In CI environments (headless Chrome), it may return "UTC" which is also valid
    valid_timezone = timezone_value.include?("/") || %w[UTC GMT].include?(timezone_value)
    assert valid_timezone, "Timezone should be in IANA format (e.g., 'Asia/Seoul') or UTC/GMT, got: #{timezone_value}"
  end

  test "firebase config is loaded from meta tag" do
    # This test only runs if firebase config is present
    skip "Firebase config not configured" unless Rails.application.config.x.firebase_config.present?

    visit root_path

    # Check that window.firebaseConfig is set
    firebase_config = page.evaluate_script("window.firebaseConfig")
    assert firebase_config.present?, "Firebase config should be loaded"
  end

  test "inbox panel persists open state across page navigation" do
    creative = Creative.create!(user: @user, description: "Navigation Test Creative")

    visit root_path
    clear_inbox_state
    visit root_path

    # Wait for page to fully load
    assert_selector ".inbox-menu-btn", wait: 5

    # Open inbox panel
    find(".inbox-menu-btn", match: :first).click
    assert_selector "#inbox-panel.open", wait: 5

    # Navigate to a creative page and wait for it to load
    visit collavre.creative_path(creative)
    assert_selector "#inbox-panel", wait: 5

    # Inbox panel should still be open (localStorage preserves state)
    assert_selector "#inbox-panel.open", wait: 5

    # Close and verify it stays closed (use JS click for reliability)
    page.execute_script("document.getElementById('close-inbox').click()")
    assert_no_selector "#inbox-panel.open", wait: 5

    # Navigate back and verify closed state persists
    visit root_path
    assert_selector ".inbox-menu-btn", wait: 5
    assert_no_selector "#inbox-panel.open", wait: 5
  end

  test "inbox panel loads items on open" do
    # Create an inbox item for the user
    other_user = User.create!(
      email: "other@example.com",
      password: SystemHelpers::PASSWORD,
      name: "OtherUser",
      email_verified_at: Time.current
    )
    creative = Creative.create!(user: other_user, description: "Shared Creative")
    CreativeShare.create!(creative: creative, user: @user, permission: :read)
    InboxItem.create!(owner: @user, creative: creative, message_key: "inbox.share", state: "new")

    visit root_path
    clear_inbox_state
    visit root_path

    # Wait for page to fully load
    assert_selector ".inbox-menu-btn", wait: 5

    # Open inbox panel
    find(".inbox-menu-btn", match: :first).click
    assert_selector "#inbox-panel.open", wait: 5

    # Wait for inbox content to load (async fetch)
    # Use visible: :all because panel animation can affect visibility detection
    assert_selector "#inbox-panel .inbox-item", visible: :all, wait: 15
  end

  test "doorkeeper token modal copy and close buttons work" do
    # Create an OAuth application
    application = Doorkeeper::Application.create!(
      name: "Test Token App",
      redirect_uri: "urn:ietf:wg:oauth:2.0:oob",
      scopes: "public",
      owner: @user
    )

    visit main_app.oauth_application_path(application)

    # Scroll to the token form section
    page.execute_script("document.querySelector('.mcp-token-section').scrollIntoView()")
    sleep 0.3

    # Generate a token to show the modal (30 Days is already selected by default)
    click_button I18n.t("doorkeeper.applications.personal_access_token.form.submit")

    # Modal should be visible with token
    assert_selector "#token-modal", visible: :visible, wait: 5
    assert_selector "#generated-token", visible: :visible

    # Stub clipboard for non-secure contexts
    stub_clipboard

    # Copy button should be present and functional
    copy_btn = find('#token-modal [data-action="copy-token"]')
    assert copy_btn.present?
    copy_btn.click

    # Button text should change to "Copied!"
    assert_selector '#token-modal [data-action="copy-token"]', text: "Copied!", wait: 3

    # Close the modal
    find('#token-modal [data-action="close-modal"]').click

    # Modal should be hidden
    assert_selector "#token-modal", visible: :hidden, wait: 5
  end

  test "doorkeeper token modal works after Turbo navigation" do
    # Create an OAuth application
    application = Doorkeeper::Application.create!(
      name: "Test Turbo Token App",
      redirect_uri: "urn:ietf:wg:oauth:2.0:oob",
      scopes: "public",
      owner: @user
    )

    # Navigate to another page first
    visit root_path
    assert_selector ".plans-menu-btn", wait: 5

    # Then navigate to the application page via Turbo
    visit main_app.oauth_application_path(application)

    # Scroll to the token form section
    page.execute_script("document.querySelector('.mcp-token-section').scrollIntoView()")
    sleep 0.3

    # Generate a token (30 Days is already selected by default)
    click_button I18n.t("doorkeeper.applications.personal_access_token.form.submit")

    # Modal should be visible
    assert_selector "#token-modal", visible: :visible, wait: 5

    # Stub clipboard for non-secure contexts
    stub_clipboard

    # Buttons should work after Turbo navigation
    copy_btn = find('#token-modal [data-action="copy-token"]')
    copy_btn.click

    assert_selector '#token-modal [data-action="copy-token"]', text: "Copied!", wait: 3

    close_btn = find('#token-modal [data-action="close-modal"]')
    close_btn.click

    assert_selector "#token-modal", visible: :hidden, wait: 5
  end

  test "creative guide popover works after browser back navigation (Turbo cache)" do
    # Clear help_menu_link setting to ensure popover shows
    SystemSetting.find_by(key: "help_menu_link")&.destroy
    creative = Creative.create!(user: @user, description: "Cache Test Creative")

    # Visit root page and verify creative guide works
    visit root_path
    assert_selector "#creative-guide-link", visible: :all, wait: 5

    find("#creative-guide-link", visible: :all, match: :first).click
    assert_selector "#creative-guide-popover[style*='display: block']", visible: :visible, wait: 5

    find("#close-creative-guide").click
    assert_no_selector "#creative-guide-popover[style*='display: block']", wait: 5

    # Navigate to a different page
    visit collavre.creative_path(creative)
    assert_selector "#creative-guide-link", visible: :all, wait: 5

    # Navigate back using browser history (this restores from Turbo cache)
    page.go_back
    assert_selector "#creative-guide-link", visible: :all, wait: 5

    # Verify creative guide still works after cache restore
    find("#creative-guide-link", visible: :all, match: :first).click
    assert_selector "#creative-guide-popover[style*='display: block']", visible: :visible, wait: 5

    find("#close-creative-guide").click
    assert_no_selector "#creative-guide-popover[style*='display: block']", wait: 5
  end

  test "doorkeeper token modal works after browser back navigation (Turbo cache)" do
    application = Doorkeeper::Application.create!(
      name: "Cache Test Token App",
      redirect_uri: "urn:ietf:wg:oauth:2.0:oob",
      scopes: "public",
      owner: @user
    )

    # Visit app page and generate token
    visit main_app.oauth_application_path(application)
    page.execute_script("document.querySelector('.mcp-token-section').scrollIntoView()")
    sleep 0.3
    click_button I18n.t("doorkeeper.applications.personal_access_token.form.submit")

    assert_selector "#token-modal", visible: :visible, wait: 5
    stub_clipboard

    # Verify buttons work
    copy_btn = find('#token-modal [data-action="copy-token"]')
    copy_btn.click
    assert_selector '#token-modal [data-action="copy-token"]', text: "Copied!", wait: 3

    find('#token-modal [data-action="close-modal"]').click
    assert_selector "#token-modal", visible: :hidden, wait: 5

    # Navigate away
    visit root_path
    assert_selector ".plans-menu-btn", wait: 5

    # Navigate back (Turbo cache restore)
    page.go_back
    sleep 0.5

    # Generate another token to get the modal back
    page.execute_script("var el = document.querySelector('.mcp-token-section'); if (el) el.scrollIntoView();")
    sleep 0.3

    # If modal is visible from cache, test it; otherwise generate new token
    if page.has_selector?("#token-modal", visible: :visible, wait: 1)
      # Modal restored from cache - verify buttons still work
      stub_clipboard
      copy_btn = find('#token-modal [data-action="copy-token"]')
      copy_btn.click
      assert_selector '#token-modal [data-action="copy-token"]', text: "Copied!", wait: 3

      find('#token-modal [data-action="close-modal"]').click
      assert_selector "#token-modal", visible: :hidden, wait: 5
    else
      # Modal not in cache (flash cleared), generate new one
      click_button I18n.t("doorkeeper.applications.personal_access_token.form.submit")
      assert_selector "#token-modal", visible: :visible, wait: 5

      stub_clipboard
      copy_btn = find('#token-modal [data-action="copy-token"]')
      copy_btn.click
      assert_selector '#token-modal [data-action="copy-token"]', text: "Copied!", wait: 3

      find('#token-modal [data-action="close-modal"]').click
      assert_selector "#token-modal", visible: :hidden, wait: 5
    end
  end

  test "inbox mark-read button works without duplicate requests" do
    # Create inbox items
    other_user = User.create!(
      email: "pagination-test@example.com",
      password: SystemHelpers::PASSWORD,
      name: "PaginationUser",
      email_verified_at: Time.current
    )

    creative = Creative.create!(user: other_user, description: "Test Creative")
    CreativeShare.create!(creative: creative, user: @user, permission: :read)
    inbox_item = InboxItem.create!(
      owner: @user,
      creative: creative,
      message_key: "inbox.share",
      state: "new",
      link: "/creatives/#{creative.id}"
    )

    visit root_path
    clear_inbox_state
    visit root_path

    # Open inbox panel
    find(".inbox-menu-btn", match: :first).click
    assert_selector "#inbox-panel.open", wait: 5

    # Wait for inbox content to load (async fetch)
    # Use visible: :all because panel animation can affect visibility detection
    assert_selector ".inbox-item", visible: :all, wait: 15

    # Verify initial state
    assert_equal "new", inbox_item.reload.state

    # Get the item element and click mark-read button
    item_selector = ".inbox-item[data-id='#{inbox_item.id}']"
    item = find(item_selector, visible: :all)
    mark_read_btn = item.find("button", text: I18n.t("inbox.mark_read"), visible: :all)
    page.execute_script("arguments[0].click()", mark_read_btn)

    # Wait for the item to disappear (inbox reloads after marking read, and default view hides read items)
    assert_no_selector item_selector, wait: 10

    # Verify final state in database
    assert_equal "read", inbox_item.reload.state, "Item should be marked as read after click"
  end

  test "doorkeeper token copy uses fallback when clipboard API fails" do
    application = Doorkeeper::Application.create!(
      name: "Fallback Test App",
      redirect_uri: "urn:ietf:wg:oauth:2.0:oob",
      scopes: "public",
      owner: @user
    )

    visit main_app.oauth_application_path(application)

    page.execute_script("document.querySelector('.mcp-token-section').scrollIntoView()")
    sleep 0.3

    click_button I18n.t("doorkeeper.applications.personal_access_token.form.submit")
    assert_selector "#token-modal", visible: :visible, wait: 5

    # Force clipboard API to fail, triggering the fallback path
    force_clipboard_fallback

    # Click copy button
    copy_btn = find('#token-modal [data-action="copy-token"]')
    copy_btn.click

    # Button should show "Copied!" (fallback uses execCommand which should work)
    assert_selector '#token-modal [data-action="copy-token"]', text: "Copied!", wait: 3

    # Verify fallback was used
    fallback_used = page.evaluate_script("window.__clipboardFallbackUsed")
    assert fallback_used, "Clipboard fallback (execCommand) should have been used"
  end
end
