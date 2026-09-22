require_relative "../application_system_test_case"

class CreativeLinkNavigationTest < ApplicationSystemTestCase
  setup do
    @user = User.create!(
      email: "creative-link-nav@example.com",
      password: SystemHelpers::PASSWORD,
      name: "Creative Link Nav",
      email_verified_at: Time.current,
      notifications_enabled: false,
      creative_workspace_enabled: true,
      system_admin: true
    )
    @source = Creative.create!(description: "Source creative", user: @user)
    @target = Creative.create!(description: "Target creative", user: @user)

    resize_window_to(1440, 900)
    sign_in_via_ui(@user)
  end

  def mark_workspace_shell
    page.execute_script(<<~JS)
      document.querySelector('.creative-workspace-shell').dataset.creativeLinkMarker = 'mounted'
    JS
  end

  def assert_frame_navigation_to_target(expected_path = collavre.creatives_path(id: @target.id))
    assert_current_path expected_path
    navigation_state = "#creative-workspace-content [data-workspace-navigation-state][data-creative-id='#{@target.id}']"
    assert_selector navigation_state, visible: :all, wait: 10
    assert_selector ".creative-workspace-shell[data-creative-link-marker='mounted']"
  end

  test "chat creative link replaces only the workspace frame" do
    comment = Comment.create!(
      creative: @source,
      user: @user,
      content: "[Open target](/creatives/#{@target.id}?open_comments=true)"
    )

    visit collavre.creatives_path(id: @source.id)
    assert_selector "#comment_#{comment.id} .comment-content a", text: "Open target", wait: 10
    mark_workspace_shell

    find("#comment_#{comment.id} .comment-content a", text: "Open target").click

    assert_frame_navigation_to_target
  end

  test "trailing-slash canonical description link advances the URL within the workspace frame" do
    target_path = "#{collavre.creatives_path}/?id=#{@target.id}"
    @source.update!(
      description: %(<p><a href="#{target_path}" data-creative-id="#{@target.id}">Open target</a></p>)
    )

    visit collavre.creatives_path(id: @source.id)
    link_selector = "#creative-workspace-content a[href='#{target_path}']"
    assert_selector link_selector, text: "Open target", wait: 10
    mark_workspace_shell

    find(link_selector, text: "Open target").click

    assert_frame_navigation_to_target(target_path)
  end

  test "chat creative link opens the target chat on mobile" do
    resize_window_to(600, 900)
    comment = Comment.create!(
      creative: @source,
      user: @user,
      content: "[Open target](/creatives/#{@target.id}?open_comments=true)"
    )

    visit collavre.creatives_path(id: @source.id, open_comments: true)
    assert_selector "#comment_#{comment.id} .comment-content a", text: "Open target", wait: 10
    mark_workspace_shell

    find("#comment_#{comment.id} .comment-content a", text: "Open target").click

    assert_frame_navigation_to_target
    assert_selector "#comments-popup[data-creative-id='#{@target.id}']", visible: :visible, wait: 10
  end

  test "expanding a collapsed dock preserves the visible deep-link target" do
    topic = @target.main_topic(fallback_user: @user)
    comments = 18.times.map do |index|
      Comment.create!(creative: @target, topic:, user: @user, content: "Loaded message #{index}")
    end
    target_comment = comments.first
    @target.update!(description: %(<a href="#{collavre.creatives_path(id: @target.id, comment_id: target_comment.id)}">Highlight loaded message</a>))

    visit collavre.creatives_path(id: @target.id)
    assert_selector "#comment_#{target_comment.id}", wait: 10
    find("#comments-popup [data-comments--popup-target='closeButton']").click
    assert_selector "#comments-popup.docked-collapsed"
    mark_workspace_shell
    find("#creative-workspace-content .creative-title-content a", text: "Highlight loaded message").click

    assert_no_selector "#comments-popup.docked-collapsed"
    assert_selector "#comment_#{target_comment.id}[data-highlighted='true']", wait: 10
    page.evaluate_async_script(<<~JS)
      const done = arguments[arguments.length - 1]
      requestAnimationFrame(() => requestAnimationFrame(done))
    JS
    assert page.evaluate_script(<<~JS)
      (() => {
        const target = document.querySelector('#comment_#{target_comment.id}').getBoundingClientRect()
        const list = document.querySelector('#comments-list').getBoundingClientRect()
        return target.top >= list.top && target.bottom <= list.bottom
      })()
    JS
    assert_selector ".creative-workspace-shell[data-creative-link-marker='mounted']"
  end

  test "chat comment permalink with a trailing slash loads an earlier page and highlights the message" do
    resize_window_to(600, 900)
    target_topic = @target.main_topic(fallback_user: @user)
    target_comment = Comment.create!(
      creative: @target,
      topic: target_topic,
      user: @user,
      content: "Earlier target message"
    )
    25.times do |index|
      content = "Newer target message #{index}"
      Comment.create!(creative: @target, topic: target_topic, user: @user, content:)
    end
    source_comment = Comment.create!(
      creative: @target,
      topic: target_topic,
      user: @user,
      content: "[Open earlier message](#{collavre.creative_comment_path(@target, target_comment)}/)"
    )

    visit collavre.creatives_path(id: @target.id, open_comments: true)
    link_selector = "#comment_#{source_comment.id} .comment-content a"
    assert_selector link_selector, text: "Open earlier message", wait: 10
    mark_workspace_shell

    find(link_selector, text: "Open earlier message").click

    assert_current_path collavre.creatives_path(id: @target.id, comment_id: target_comment.id)
    navigation_state = "#creative-workspace-content [data-workspace-navigation-state]"
    assert_selector "#{navigation_state}[data-creative-id='#{@target.id}']", visible: :all, wait: 10
    assert_selector ".creative-workspace-shell[data-creative-link-marker='mounted']"
    assert_selector "#comment_#{target_comment.id}[data-highlighted='true']", wait: 10
  end
end
