require_relative "../application_system_test_case"

class CommentPreviousMessageNavigationTest < ApplicationSystemTestCase
  setup do
    @user = User.create!(
      email: "previous-message-nav@example.com",
      password: SystemHelpers::PASSWORD,
      name: "Previous Message Nav",
      email_verified_at: Time.current,
      notifications_enabled: false,
      creative_workspace_enabled: true,
      system_admin: true
    )
    @creative = Creative.create!(description: "Chat history", user: @user)

    resize_window_to(1440, 900)
    sign_in_via_ui(@user)
  end

  test "previous message button loads and highlights the next message across a page boundary" do
    topic = @creative.main_topic(fallback_user: @user)
    previous_message = Comment.create!(
      creative: @creative,
      topic:,
      user: @user,
      content: "Previous page message"
    )
    current_page_messages = 20.times.map do |index|
      Comment.create!(creative: @creative, topic:, user: @user, content: "Current page message #{index}")
    end

    visit collavre.creatives_path(id: @creative.id, open_comments: true)
    assert_no_selector "#comment_#{previous_message.id}", wait: 10
    assert_selector "#comments-list .comment-item", minimum: 20, wait: 10

    page.execute_script(<<~JS)
      document.querySelector('#comments-list').scrollTop = 0
      document.querySelector('#scroll-prev-msg-btn').click()
    JS
    assert_selector "#comment_#{current_page_messages.first.id}[data-highlighted='true']", wait: 10
    page.execute_script("document.querySelector('#scroll-prev-msg-btn').click()")

    assert_selector "#comment_#{previous_message.id}[data-highlighted='true']", wait: 10
  end
end
