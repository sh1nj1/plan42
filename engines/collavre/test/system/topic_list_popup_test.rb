require_relative "../application_system_test_case"

class TopicListPopupTest < ApplicationSystemTestCase
  setup do
    @user = User.create!(
      email: "topic-list@example.com",
      password: SystemHelpers::PASSWORD,
      name: "TopicListUser",
      email_verified_at: Time.current,
      notifications_enabled: false
    )
    @creative = Creative.create!(description: "Root", user: @user)
    @active_topic   = Collavre::Topic.create!(name: "Alpha", creative: @creative, user: @user)
    @archived_topic = Collavre::Topic.create!(name: "Zeta", creative: @creative, user: @user)
    @archived_topic.archive!

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
    # Wait for topics to finish loading (active topic tab appears)
    assert_selector "#comment-topics .topic-tag", text: "Alpha", wait: 10
  end

  test "list button opens a searchable popup of active + archived topics" do
    open_comments_popup

    find("#comments-popup .topic-list-btn").click
    assert_selector "#topic-list-modal", visible: :visible, wait: 5

    within "#topic-list-modal" do
      assert_selector ".topic-list-item", text: "Alpha"
      assert_selector ".topic-list-item", text: "All Messages"
      # Archived topic present AND visually distinguished
      assert_selector ".topic-list-item--archived", text: "Zeta"
    end
  end

  test "search filters the list" do
    open_comments_popup
    find("#comments-popup .topic-list-btn").click
    assert_selector "#topic-list-modal", visible: :visible, wait: 5

    find("#topic-list-modal input").set("Alpha")
    within "#topic-list-modal" do
      assert_selector ".topic-list-item", text: "Alpha"
      assert_no_selector ".topic-list-item--archived"   # Zeta filtered out
    end
  end

  test "selecting a topic navigates to it and closes the popup" do
    open_comments_popup
    find("#comments-popup .topic-list-btn").click
    assert_selector "#topic-list-modal", visible: :visible, wait: 5

    within "#topic-list-modal" do
      find("li.common-popup-item", text: "Alpha").click
    end

    # Popup closes and the bar marks the selected topic active
    assert_no_selector "#topic-list-modal", visible: :visible
    assert_selector "#comment-topics .topic-tag.active[data-id='#{@active_topic.id}']", wait: 5
  end
end
