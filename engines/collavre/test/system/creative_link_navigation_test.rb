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

  def assert_frame_navigation_to_target
    assert_current_path collavre.creatives_path(id: @target.id)
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

  test "description creative link advances the URL within the workspace frame" do
    @source.update!(
      description: %(<p><a href="/creatives/#{@target.id}" data-creative-id="#{@target.id}">Open target</a></p>)
    )

    visit collavre.creatives_path(id: @source.id)
    link_selector = "#creative-workspace-content a[href='/creatives/#{@target.id}']"
    assert_selector link_selector, text: "Open target", wait: 10
    mark_workspace_shell

    find(link_selector, text: "Open target").click

    assert_frame_navigation_to_target
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

  test "chat comment permalink loads an earlier page and highlights the message" do
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
      content: "[Open earlier message](#{collavre.creative_comment_path(@target, target_comment)})"
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
