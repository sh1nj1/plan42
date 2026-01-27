require "test_helper"
require "ostruct"

class CommentsCalendarTest < ActionDispatch::IntegrationTest
  setup do
    @user = User.create!(email: "user_cal@example.com", password: TEST_PASSWORD, name: "User Cal")
    @creative = Creative.create!(user: @user, description: "Calendar test creative")
    CreativeShare.create!(creative: @creative, user: @user, permission: :feedback)
    sign_in_as(@user)
  end

  test "creates all-day event when date argument provided" do
    command = "/calendar 2025-08-01"
    event = OpenStruct.new(html_link: "https://calendar.google.com/event/abc123")
    service = Minitest::Mock.new
    service.expect(:create_event, event) do |params|
      assert params[:all_day], "expected all_day flag"
      assert_kind_of Date, params[:start_time]
      assert_kind_of Date, params[:end_time]
      assert_equal Date.new(2025, 8, 1), params[:start_time]
      true
    end

    GoogleCalendarService.stub(:new, ->(user:) { assert_equal @user.id, user.id; service }) do
      assert_difference("Comment.count", 1) do
        post creative_comments_path(@creative), params: { comment: { content: command } }
      end
    end

    assert_response :created
    expected_content = "#{command}\n\n#{I18n.t("collavre.comments.calendar_command.event_created", url: event.html_link)}"
    assert_equal expected_content, Comment.last.content
    assert_mock service
  end

  test "creates all-day event for today shortcut" do
    command = "/calendar today"
    today = Time.zone.today
    event = OpenStruct.new(html_link: "https://calendar.google.com/event/today123")
    service = Minitest::Mock.new
    service.expect(:create_event, event) do |params|
      assert params[:all_day]
      assert_equal today, params[:start_time]
      assert_equal today, params[:end_time]
      true
    end

    GoogleCalendarService.stub(:new, ->(user:) { assert_equal @user.id, user.id; service }) do
      assert_difference("Comment.count", 1) do
        post creative_comments_path(@creative), params: { comment: { content: command } }
      end
    end

    assert_response :created
    expected_content = "#{command}\n\n#{I18n.t("collavre.comments.calendar_command.event_created", url: event.html_link)}"
    assert_equal expected_content, Comment.last.content
    assert_mock service
  end
end
