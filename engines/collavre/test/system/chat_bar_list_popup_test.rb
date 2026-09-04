require_relative "../application_system_test_case"

# The context and user strips at the top of the chat get the same pinned
# add + list buttons the topic bar already has.
class ChatBarListPopupTest < ApplicationSystemTestCase
  setup do
    @user = User.create!(
      email: "chat-bar-list@example.com",
      password: SystemHelpers::PASSWORD,
      name: "ChatBarListUser",
      email_verified_at: Time.current,
      notifications_enabled: false
    )
    @creative = Creative.create!(description: "Root", user: @user)
    @context = Creative.create!(description: "Context One", user: @user)
    @creative.update!(data: { "context_ids" => [ @context.id ] })

    resize_window_to
    sign_in_via_ui(@user)
  end

  def open_comments_popup
    visit root_path
    assert_selector "#creative-#{@creative.id}", wait: 5
    creative_row = find("#creative-#{@creative.id}")
    creative_row.hover
    within("#creative-#{@creative.id}") do
      find(".comments-btn").click
    end
    assert_selector "#comments-popup", wait: 5
    assert_docked_comments_loaded
  end

  test "context list button opens a searchable popup of the linked contexts" do
    open_comments_popup
    assert_selector "#comment-contexts .context-chip", text: "Context One", wait: 10

    find("#comments-popup .context-list-btn").click
    assert_selector "#context-list-modal", visible: :visible, wait: 5
    # Caged inside the chat box, not appended to <body>
    assert_selector "#comments-popup #context-list-modal"

    within "#context-list-modal" do
      assert_selector ".entity-list-item", text: "Root"          # self context
      assert_selector ".entity-list-item", text: "Context One"
    end
  end

  test "context list button toggles an open popup closed" do
    open_comments_popup
    assert_selector "#comment-contexts .context-chip", text: "Context One", wait: 10

    button = find("#comments-popup .context-list-btn")
    button.click
    assert_selector "#context-list-modal", visible: :visible, wait: 5
    assert_equal "true", button["aria-expanded"]

    button.click
    assert_no_selector "#context-list-modal", visible: :visible
    assert_equal "false", button["aria-expanded"]
  end

  test "selecting a context in the popup toggles it off and keeps the popup open" do
    open_comments_popup
    assert_selector "#comment-contexts .context-chip", text: "Context One", wait: 10

    find("#comments-popup .context-list-btn").click
    assert_selector "#context-list-modal", visible: :visible, wait: 5

    within "#context-list-modal" do
      find("li.common-popup-item", text: "Context One").click
      assert_selector ".entity-list-item--muted", text: "Context One", wait: 5
    end
    assert_selector "#context-list-modal", visible: :visible
    assert_selector "#comment-contexts .context-chip.context-disabled", text: "Context One", wait: 5
  end

  test "the context add button sits outside the scrolling chip strip" do
    open_comments_popup
    assert_selector "#comment-contexts .context-chip", text: "Context One", wait: 10

    assert_selector "#comments-popup .comment-contexts-bar > .add-context-btn"
    assert_no_selector "#comment-contexts .add-context-btn"
  end

  test "user list button opens a searchable popup and the picked user's profile menu" do
    open_comments_popup
    assert_selector "#comment-participants .comment-presence-avatar", wait: 10

    find("#comments-popup .participant-list-btn").click
    assert_selector "#participant-list-modal", visible: :visible, wait: 5
    assert_selector "#comments-popup #participant-list-modal"

    within "#participant-list-modal" do
      find("li.common-popup-item", text: @user.name).click
    end

    assert_no_selector "#participant-list-modal", visible: :visible
    assert_selector "#participant-user-menu-#{@user.id}", visible: :visible
    within "#participant-user-menu-#{@user.id}" do
      assert_text @user.email
      assert_link I18n.t("collavre.comments.user_menu.view_profile"),
        href: Collavre::Engine.routes.url_helpers.user_path(@user)
      click_button I18n.t("collavre.comments.user_menu.mention")
    end
    assert_equal "@#{@user.name}: ", find("#new-comment-form textarea").value
  end

  test "the user add button sits outside the scrolling avatar strip" do
    open_comments_popup
    assert_selector "#comment-participants .comment-presence-avatar", wait: 10

    assert_selector "#comments-popup .comment-participants-bar > .add-participant-btn"
    assert_no_selector "#comment-participants .add-participant-btn"
  end
end
