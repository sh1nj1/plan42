require "test_helper"
require "ostruct"

class CommentsCalendarTest < ActionDispatch::IntegrationTest
  include ActiveSupport::Testing::TimeHelpers

  setup do
    @user = User.create!(email: "user_cal@example.com", password: TEST_PASSWORD, name: "User Cal", google_refresh_token: "test_refresh_token")
    @creative = Creative.create!(user: @user, description: "Calendar test creative")
    CreativeShare.create!(creative: @creative, user: @user, permission: :feedback)
    sign_in_as(@user)
  end

  test "creates all-day event when date argument provided" do
    command = "/calendar 2025-08-01"
    google_event = OpenStruct.new(id: "google_abc123", html_link: "https://calendar.google.com/event/abc123")
    service = Minitest::Mock.new
    service.expect(:create_google_event, google_event) do |params|
      assert params[:all_day], "expected all_day flag"
      assert_equal Date.new(2025, 8, 1), params[:start_time].to_date
      assert_equal Date.new(2025, 8, 1), params[:end_time].to_date
      true
    end

    GoogleCalendarService.stub(:new, ->(user:) { assert_equal @user.id, user.id; service }) do
      assert_difference([ "Comment.count", "CalendarEvent.count" ], 1) do
        post creative_comments_path(@creative), params: { comment: { content: command } }
      end
    end

    assert_response :created
    expected_content = "#{command}\n\n#{I18n.t("collavre.comments.calendar_command.event_created", url: google_event.html_link)}"
    assert_equal expected_content, Comment.last.content
    assert_equal google_event.id, CalendarEvent.last.google_event_id
    assert_mock service
  end

  test "creates all-day event for today shortcut" do
    command = "/calendar today"
    today = Time.zone.today
    google_event = OpenStruct.new(id: "google_today123", html_link: "https://calendar.google.com/event/today123")
    service = Minitest::Mock.new
    service.expect(:create_google_event, google_event) do |params|
      assert params[:all_day]
      assert_equal today, params[:start_time]
      assert_equal today, params[:end_time]
      true
    end

    GoogleCalendarService.stub(:new, ->(user:) { assert_equal @user.id, user.id; service }) do
      assert_difference([ "Comment.count", "CalendarEvent.count" ], 1) do
        post creative_comments_path(@creative), params: { comment: { content: command } }
      end
    end

    assert_response :created
    expected_content = "#{command}\n\n#{I18n.t("collavre.comments.calendar_command.event_created", url: google_event.html_link)}"
    assert_equal expected_content, Comment.last.content
    assert_equal google_event.id, CalendarEvent.last.google_event_id
    assert_mock service
  end

  test "creates all-day event for tomorrow shortcut" do
    travel_to Time.zone.local(2025, 1, 6, 9, 0, 0) do
      command = "/calendar tomorrow"
      tomorrow = Time.zone.today + 1.day
      google_event = OpenStruct.new(id: "google_tomorrow123", html_link: "https://calendar.google.com/event/tomorrow123")
      service = Minitest::Mock.new
      service.expect(:create_google_event, google_event) do |params|
        assert params[:all_day]
        assert_equal tomorrow, params[:start_time]
        assert_equal tomorrow, params[:end_time]
        true
      end

      GoogleCalendarService.stub(:new, ->(user:) { assert_equal @user.id, user.id; service }) do
        assert_difference([ "Comment.count", "CalendarEvent.count" ], 1) do
          post creative_comments_path(@creative), params: { comment: { content: command } }
        end
      end

      assert_response :created
      expected_content = "#{command}\n\n#{I18n.t("collavre.comments.calendar_command.event_created", url: google_event.html_link)}"
      assert_equal expected_content, Comment.last.content
      assert_equal google_event.id, CalendarEvent.last.google_event_id
      assert_mock service
    end
  end

  test "creates all-day event for weekday offsets" do
    travel_to Time.zone.local(2025, 1, 6, 9, 0, 0) do
      command = "/calendar +2mon"
      expected_date = Date.new(2025, 1, 20)
      google_event = OpenStruct.new(id: "google_weekday123", html_link: "https://calendar.google.com/event/weekday123")
      service = Minitest::Mock.new
      service.expect(:create_google_event, google_event) do |params|
        assert params[:all_day]
        assert_equal expected_date, params[:start_time]
        assert_equal expected_date, params[:end_time]
        true
      end

      GoogleCalendarService.stub(:new, ->(user:) { assert_equal @user.id, user.id; service }) do
        assert_difference([ "Comment.count", "CalendarEvent.count" ], 1) do
          post creative_comments_path(@creative), params: { comment: { content: command } }
        end
      end

      assert_response :created
      expected_content = "#{command}\n\n#{I18n.t("collavre.comments.calendar_command.event_created", url: google_event.html_link)}"
      assert_equal expected_content, Comment.last.content
      assert_equal google_event.id, CalendarEvent.last.google_event_id
      assert_mock service
    end
  end

  test "creates local-only event when google not connected" do
    user_without_google = User.create!(email: "user_no_google@example.com", password: TEST_PASSWORD, name: "User No Google")
    creative = Creative.create!(user: user_without_google, description: "No Google calendar test")
    CreativeShare.create!(creative: creative, user: user_without_google, permission: :feedback)
    sign_in_as(user_without_google)

    command = "/calendar tomorrow"

    assert_difference([ "Comment.count", "CalendarEvent.count" ], 1) do
      post creative_comments_path(creative), params: { comment: { content: command } }
    end

    assert_response :created
    expected_content = "#{command}\n\n#{I18n.t("collavre.comments.calendar_command.event_created_local")}"
    assert_equal expected_content, Comment.last.content

    calendar_event = CalendarEvent.last
    assert_nil calendar_event.google_event_id
    assert_nil calendar_event.html_link
    assert_equal user_without_google.id, calendar_event.user_id
    assert_equal creative.id, calendar_event.creative_id
  end

  test "creates timed event with date and time combined like today@14:00" do
    user_without_google = User.create!(email: "user_timed@example.com", password: TEST_PASSWORD, name: "User Timed")
    creative = Creative.create!(user: user_without_google, description: "Timed event test")
    CreativeShare.create!(creative: creative, user: user_without_google, permission: :feedback)
    sign_in_as(user_without_google)

    command = "/cal today@14:00"

    assert_difference([ "Comment.count", "CalendarEvent.count" ], 1) do
      post creative_comments_path(creative), params: { comment: { content: command } }
    end

    assert_response :created

    calendar_event = CalendarEvent.last
    assert_equal user_without_google.id, calendar_event.user_id
    assert_equal creative.id, calendar_event.creative_id
    assert_equal Time.zone.today, calendar_event.start_time.to_date
    assert_equal 14, calendar_event.start_time.hour
    assert_equal 0, calendar_event.start_time.min
  end

  test "creates all-day event with MM-DD short date format using current year" do
    travel_to Time.zone.local(2026, 1, 10, 9, 0, 0) do
      user_without_google = User.create!(email: "user_short_date@example.com", password: TEST_PASSWORD, name: "User Short Date")
      creative = Creative.create!(user: user_without_google, description: "Short date test")
      CreativeShare.create!(creative: creative, user: user_without_google, permission: :feedback)
      sign_in_as(user_without_google)

      command = "/calendar 02-17"

      assert_difference([ "Comment.count", "CalendarEvent.count" ], 1) do
        post creative_comments_path(creative), params: { comment: { content: command } }
      end

      assert_response :created

      calendar_event = CalendarEvent.last
      assert_equal Date.new(2026, 2, 17), calendar_event.start_time.to_date
    end
  end

  test "creates timed event with MM-DD@HH:MM short date format" do
    travel_to Time.zone.local(2026, 3, 1, 9, 0, 0) do
      user_without_google = User.create!(email: "user_short_time@example.com", password: TEST_PASSWORD, name: "User Short Time")
      creative = Creative.create!(user: user_without_google, description: "Short date time test")
      CreativeShare.create!(creative: creative, user: user_without_google, permission: :feedback)
      sign_in_as(user_without_google)

      command = "/calendar 02-17@14:00"

      assert_difference([ "Comment.count", "CalendarEvent.count" ], 1) do
        post creative_comments_path(creative), params: { comment: { content: command } }
      end

      assert_response :created

      calendar_event = CalendarEvent.last
      assert_equal Date.new(2026, 2, 17), calendar_event.start_time.to_date
      assert_equal 14, calendar_event.start_time.hour
      assert_equal 0, calendar_event.start_time.min
    end
  end

  test "creates local event and shows sync failed message when google sync fails" do
    command = "/calendar tomorrow"
    service = Minitest::Mock.new
    service.expect(:create_google_event, nil) do |_params|
      raise StandardError, "OAuth error"
    end

    GoogleCalendarService.stub(:new, ->(user:) { assert_equal @user.id, user.id; service }) do
      assert_difference([ "Comment.count", "CalendarEvent.count" ], 1) do
        post creative_comments_path(@creative), params: { comment: { content: command } }
      end
    end

    assert_response :created
    expected_content = "#{command}\n\n#{I18n.t("collavre.comments.calendar_command.event_created_sync_failed")}"
    assert_equal expected_content, Comment.last.content

    calendar_event = CalendarEvent.last
    assert_nil calendar_event.google_event_id
    assert_equal @user.id, calendar_event.user_id
  end
end
