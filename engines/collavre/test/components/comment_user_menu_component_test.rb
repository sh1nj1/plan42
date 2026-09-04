require "test_helper"

class CommentUserMenuComponentTest < ViewComponent::TestCase
  test "renders profile details and actions for a human user" do
    user = users(:one)

    render_inline(Collavre::CommentUserMenuComponent.new(user: user, menu_id: "comment-user-menu-1"))

    assert_selector "[data-controller='popup-menu comment-user-menu']"
    assert_selector "button.comment-user-menu-trigger[aria-expanded='false']"
    assert_selector ".comment-user-popup-identity strong", text: user.display_name
    assert_selector ".comment-user-popup-email", text: user.email
    assert_selector ".comment-user-popup-status", text: I18n.t("collavre.comments.participant_offline")
    assert_selector "a.popup-menu-item[href='#{Collavre::Engine.routes.url_helpers.user_path(user)}']",
      text: I18n.t("collavre.comments.user_menu.view_profile")
    assert_selector "button[data-action='click->comment-user-menu#mention']",
      text: I18n.t("collavre.comments.user_menu.mention")
    assert_no_selector "[draggable='true']"
    assert_no_selector ".comment-user-popup-guide"
  end

  test "makes an AI agent avatar draggable and explains the topic assignment" do
    agent = users(:ai_bot)

    render_inline(Collavre::CommentUserMenuComponent.new(user: agent, menu_id: "comment-agent-menu-1"))

    assert_selector "button.comment-user-menu-trigger.ai-agent-draggable[draggable='true']"
    assert_selector "button[data-action*='dragstart->comment-user-menu#dragStart']"
    assert_selector ".comment-user-popup-guide",
      text: I18n.t("collavre.comments.user_menu.agent_drag_guide")
  end

  test "uses the supplied menu id" do
    render_inline(Collavre::CommentUserMenuComponent.new(user: users(:one), menu_id: "message-author-menu"))

    assert_selector "#message-author-menu[role='menu']"
  end
end
