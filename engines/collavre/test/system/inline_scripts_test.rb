require_relative "../application_system_test_case"

class InlineScriptsTest < ApplicationSystemTestCase
  setup do
    @user = User.create!(
      email: "inline-scripts-test@example.com",
      password: SystemHelpers::PASSWORD,
      name: "TestUser",
      email_verified_at: Time.current,
      notifications_enabled: false,
      creative_workspace_enabled: true
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

  test "profile toggles the creative workspace from its default off state" do
    @user.update!(creative_workspace_enabled: false)

    visit root_path
    assert_no_selector ".creative-workspace-shell"
    assert_selector "#comments-popup[data-docked='false']", visible: :all

    visit collavre.user_path(@user)
    workspace_toggle = find("#user_creative_workspace_enabled")
    assert_not workspace_toggle.checked?
    workspace_toggle.check
    click_button I18n.t("collavre.users.update_profile")

    assert_text I18n.t("collavre.users.profile_updated")
    visit root_path
    assert_selector ".creative-workspace-shell"
    assert_selector "#comments-popup[data-docked='true']", visible: :visible

    visit collavre.user_path(@user)
    find("#user_creative_workspace_enabled").uncheck
    click_button I18n.t("collavre.users.update_profile")

    visit root_path
    assert_no_selector ".creative-workspace-shell"
    assert_selector "#comments-popup[data-docked='false']", visible: :all
  end

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

  test "inbox button opens comments popup for inbox creative" do
    inbox = Creative.inbox_for(@user)

    visit root_path

    assert_selector "#comments-popup[data-docked='true']", visible: :visible
    assert_text I18n.t("collavre.creatives.workspace.select_chat")

    find(".inbox-menu-btn", match: :first).click

    assert_selector "#comments-popup", visible: :visible, wait: 5
    assert_equal inbox.id.to_s, find("#comments-popup", visible: :visible)["data-creative-id"]
  end

  test "workspace tree navigation preserves the mounted tree and replaces only center content" do
    resize_window_to(1440, 900)
    first_branch = Creative.create!(user: @user, description: "First workspace branch")
    Creative.create!(user: @user, parent: first_branch, description: "First child")
    second_branch = Creative.create!(user: @user, description: "Second workspace branch")
    Creative.create!(user: @user, parent: second_branch, description: "Second child")

    visit collavre.creatives_path(id: first_branch.id)
    assert_selector ".creative-workspace-tree-link[data-creative-id='#{second_branch.id}']", wait: 10
    page.execute_script(<<~JS)
      document.querySelector('[data-controller="workspace-tree"]')
        .dataset.persistenceMarker = 'mounted';
    JS

    find(".creative-workspace-tree-link[data-creative-id='#{second_branch.id}']").click

    assert_selector "#creative-workspace-content [data-workspace-navigation-state][data-creative-id='#{second_branch.id}']",
                    visible: :all, wait: 10
    assert_selector ".creative-workspace-tree-link[data-creative-id='#{second_branch.id}'].is-current"
    assert_equal "mounted", find("[data-controller='workspace-tree']")["data-persistence-marker"]
    assert_equal second_branch.id.to_s, find("#comments-popup", visible: :visible)["data-creative-id"]

    page.go_back

    assert_selector "#creative-workspace-content [data-workspace-navigation-state][data-creative-id='#{first_branch.id}']",
                    visible: :all, wait: 10
    assert_selector ".creative-workspace-tree-link[data-creative-id='#{first_branch.id}'].is-current"
    assert_equal "mounted", find("[data-controller='workspace-tree']")["data-persistence-marker"]
    assert_equal first_branch.id.to_s, find("#comments-popup", visible: :visible)["data-creative-id"]
  end

  test "workspace navigation does not auto-open floating chat on mobile" do
    resize_window_to(600, 900)
    first_creative = Creative.create!(user: @user, description: "First mobile creative")
    second_creative = Creative.create!(user: @user, description: "Second mobile creative")

    visit collavre.creatives_path(id: first_creative.id)
    assert_selector "#creative-workspace-content [data-workspace-navigation-state][data-creative-id='#{first_creative.id}']",
                    visible: :all, wait: 10
    assert_no_selector "#comments-popup", visible: :visible

    page.execute_script(<<~JS)
      const link = document.createElement('a');
      link.id = 'mobile-workspace-link';
      link.href = '#{collavre.creatives_path(id: second_creative.id)}';
      link.dataset.turboFrame = 'creative-workspace-content';
      link.dataset.turboAction = 'advance';
      link.textContent = 'Second mobile creative';
      document.body.appendChild(link);
    JS
    find("#mobile-workspace-link").click

    assert_selector "#creative-workspace-content [data-workspace-navigation-state][data-creative-id='#{second_creative.id}']",
                    visible: :all, wait: 10
    assert_no_selector "#comments-popup", visible: :visible
  end

  test "workspace breadcrumb and center rows preserve the mounted shell" do
    resize_window_to(1440, 900)
    branch = Creative.create!(user: @user, description: "Center navigation branch")
    Creative.create!(user: @user, parent: branch, description: "Center navigation child")

    visit collavre.creatives_path(id: branch.id)
    assert_selector "#creative-workspace-content [data-workspace-navigation-state][data-creative-id='#{branch.id}']",
                    visible: :all, wait: 10
    page.execute_script(<<~JS)
      document.querySelector('[data-controller="workspace-tree"]')
        .dataset.persistenceMarker = 'center-mounted';
    JS

    find(".creative-breadcrumb-link", text: I18n.t("collavre.creatives.index.root_breadcrumb")).click

    assert_selector "#creative-workspace-content [data-workspace-navigation-state]:not([data-creative-id])",
                    visible: :all, wait: 10
    assert_equal "center-mounted", find("[data-controller='workspace-tree']")["data-persistence-marker"]

    find("creative-tree-row[creative-id='#{branch.id}'] .creative-content").click

    assert_selector "#creative-workspace-content [data-workspace-navigation-state][data-creative-id='#{branch.id}']",
                    visible: :all, wait: 10
    assert_equal "center-mounted", find("[data-controller='workspace-tree']")["data-persistence-marker"]
  end

  test "workspace frame history synchronizes leaf and root chat states" do
    resize_window_to(1440, 900)
    branch = Creative.create!(user: @user, description: "Leaf parent branch")
    leaf = Creative.create!(user: @user, parent: branch, description: "Leaf workspace creative")
    other_branch = Creative.create!(user: @user, description: "Other workspace branch")
    Creative.create!(user: @user, parent: other_branch, description: "Other child")

    visit collavre.creatives_path(id: leaf.id)
    assert_selector ".creative-workspace-tree-link[data-creative-id='#{other_branch.id}']", wait: 10
    assert_equal leaf.id.to_s, find("#comments-popup", visible: :visible)["data-creative-id"]

    find(".creative-workspace-tree-link[data-creative-id='#{other_branch.id}']").click
    assert_equal other_branch.id.to_s, find("#comments-popup", visible: :visible)["data-creative-id"]
    assert_current_path collavre.creatives_path(id: other_branch.id)
    assert_selector "#creative-workspace-content [data-workspace-navigation-state][data-creative-id='#{other_branch.id}']",
                    visible: :all, wait: 10
    assert_eventually { page.evaluate_script("window.Turbo?.navigator?.currentVisit == null") }

    page.go_back

    assert_selector "#creative-workspace-content [data-workspace-navigation-state][data-creative-id='#{leaf.id}']",
                    visible: :all, wait: 10
    assert_selector ".creative-workspace-tree-link[data-creative-id='#{branch.id}'].is-current"
    assert_equal leaf.id.to_s, find("#comments-popup", visible: :visible)["data-creative-id"]

    visit collavre.creatives_path
    assert_selector ".creative-workspace-tree-link[data-creative-id='#{other_branch.id}']", wait: 10
    find(".creative-workspace-tree-link[data-creative-id='#{other_branch.id}']").click
    assert_current_path collavre.creatives_path(id: other_branch.id)
    assert_selector "#creative-workspace-content [data-workspace-navigation-state][data-creative-id='#{other_branch.id}']",
                    visible: :all, wait: 10
    assert_eventually { page.evaluate_script("window.Turbo?.navigator?.currentVisit == null") }

    page.go_back

    assert_current_path collavre.creatives_path
    assert_selector "#creative-workspace-content [data-workspace-navigation-state]:not([data-creative-id])",
                    visible: :all, wait: 10
    assert_selector "#comments-popup[data-creative-id='']", visible: :visible, wait: 10
    assert_text I18n.t("collavre.creatives.workspace.select_chat")
  end

  test "workspace frame clears persistent navigation after an inaccessible selection" do
    resize_window_to(1440, 900)
    branch = Creative.create!(user: @user, description: "Visible workspace branch")
    Creative.create!(user: @user, parent: branch, description: "Visible child")
    inaccessible = Creative.create!(user: users(:two), description: "Private workspace creative")

    visit collavre.creatives_path(id: branch.id)
    assert_selector ".creative-workspace-tree-link[data-creative-id='#{branch.id}'].is-current", wait: 10
    page.execute_script(<<~JS)
      const link = document.createElement('a');
      link.id = 'inaccessible-workspace-link';
      link.href = '#{collavre.creatives_path(id: inaccessible.id)}';
      link.dataset.turboFrame = 'creative-workspace-content';
      link.dataset.turboAction = 'advance';
      link.textContent = 'Private target';
      document.body.appendChild(link);
    JS

    find("#inaccessible-workspace-link").click

    assert_selector "#creative-workspace-content [data-workspace-navigation-state]:not([data-creative-id])",
                    visible: :all, wait: 10
    assert_no_selector ".creative-workspace-tree-link.is-current"
    assert_selector "#comments-popup[data-creative-id='']", visible: :visible, wait: 10
    assert_text I18n.t("collavre.creatives.workspace.select_chat")
  end

  test "workspace tree refreshes first-child and last-child structural changes" do
    resize_window_to(1440, 900)
    stable_branch = Creative.create!(user: @user, description: "Stable workspace branch")
    Creative.create!(user: @user, parent: stable_branch, description: "Stable child")
    changing_creative = Creative.create!(user: @user, description: "Changing workspace creative")

    visit collavre.creatives_path(id: stable_branch.id)
    assert_selector ".creative-workspace-tree-link[data-creative-id='#{stable_branch.id}']", wait: 10
    assert_no_selector ".creative-workspace-tree-link[data-creative-id='#{changing_creative.id}']"

    child = Creative.create!(user: @user, parent: changing_creative, description: "Temporary child")
    page.execute_script("document.dispatchEvent(new CustomEvent('workspace-tree:invalidate'))")

    assert_selector ".creative-workspace-tree-link[data-creative-id='#{changing_creative.id}']", wait: 10

    child.destroy!
    page.execute_script("document.dispatchEvent(new CustomEvent('workspace-tree:invalidate'))")

    assert_no_selector ".creative-workspace-tree-link[data-creative-id='#{changing_creative.id}']", wait: 10
  end

  test "workspace tree refresh does not reopen a destroyed creative chat" do
    resize_window_to(1440, 900)
    branch = Creative.create!(user: @user, description: "Destroyed chat branch")
    leaf = Creative.create!(user: @user, parent: branch, description: "Destroyed chat leaf")

    visit collavre.creatives_path(id: leaf.id)
    assert_equal leaf.id.to_s, find("#comments-popup", visible: :visible)["data-creative-id"]

    leaf.destroy!
    page.execute_script(<<~JS)
      document.dispatchEvent(new CustomEvent('creative-destroyed', {
        detail: { creativeIds: ['#{leaf.id}'] }
      }));
      document.dispatchEvent(new CustomEvent('workspace-tree:invalidate'));
    JS

    assert_selector "#comments-popup[data-creative-id='']", visible: :visible, wait: 10
    assert_no_selector ".creative-workspace-tree-link[data-creative-id='#{branch.id}']", wait: 10
    assert_text I18n.t("collavre.creatives.workspace.select_chat")
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

    # Modal is loaded via AJAX, so it should not be in the DOM initially
    assert_no_selector "#share-creative-modal"

    # Open overflow menu, then click share button (share is inside ⋯ menu)
    find("#creative-overflow-menu", visible: :all).ancestor(".popup-menu-wrapper").find("button", match: :first).click
    find("#share-creative-btn").click

    # Modal should become visible after AJAX load
    assert_selector "#share-creative-modal", visible: :visible

    # Click close button
    find("#close-share-modal").click

    # Modal should be hidden after closing
    assert_no_selector "#share-creative-modal", visible: :visible, wait: 5
  end

  test "share modal closes when clicking on backdrop" do
    creative = Creative.create!(user: @user, description: "Another Shareable")

    visit collavre.creative_path(creative)

    find("#creative-overflow-menu", visible: :all).ancestor(".popup-menu-wrapper").find("button", match: :first).click
    find("#share-creative-btn").click
    assert_selector "#share-creative-modal", visible: :visible

    # Click on the modal backdrop (the modal element itself, not the popup-box inside)
    page.execute_script("document.getElementById('share-creative-modal').click()")

    # Modal should be hidden after clicking backdrop
    assert_no_selector "#share-creative-modal", visible: :visible, wait: 5
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

  test "inbox button opens comments popup after page navigation" do
    creative = Creative.create!(user: @user, description: "Navigation Test Creative")
    inbox = Creative.inbox_for(@user)

    visit root_path
    assert_selector ".inbox-menu-btn", wait: 5

    visit collavre.creative_path(creative)
    assert_selector ".inbox-menu-btn", wait: 5

    find(".inbox-menu-btn", match: :first).click

    assert_selector "#comments-popup", visible: :visible, wait: 5
    assert_equal inbox.id.to_s, find("#comments-popup", visible: :visible)["data-creative-id"]
  end

  test "inbox button loads inbox creative comments on open" do
    inbox = Creative.inbox_for(@user)
    comment = Comment.create!(creative: inbox, user: @user, content: "Inbox message")

    visit root_path
    assert_selector ".inbox-menu-btn", wait: 5

    find(".inbox-menu-btn", match: :first).click

    assert_selector "#comments-popup", visible: :visible, wait: 5
    assert_selector "#comment_#{comment.id}", visible: :all, wait: 15
    assert_selector "#comment_#{comment.id}", text: "Inbox message", visible: :all, wait: 15
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

  test "inbox button keeps docked comments open without duplicate bindings" do
    inbox = Creative.inbox_for(@user)

    visit root_path

    find(".inbox-menu-btn", match: :first).click
    assert_selector "#comments-popup", visible: :visible, wait: 5
    assert_equal inbox.id.to_s, find("#comments-popup", visible: :visible)["data-creative-id"]

    find(".inbox-menu-btn", match: :first).click
    assert_selector "#comments-popup", visible: :visible, wait: 5
    assert_equal inbox.id.to_s, find("#comments-popup", visible: :visible)["data-creative-id"]

    find(".inbox-menu-btn", match: :first).click
    assert_selector "#comments-popup", visible: :visible, wait: 5
    assert_equal inbox.id.to_s, find("#comments-popup", visible: :visible)["data-creative-id"]
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
