require "test_helper"

class CalendarEventTest < ActiveSupport::TestCase
  test "deletes Google Calendar event when destroyed" do
    user = User.create!(email: "calendar-user@example.com", password: TEST_PASSWORD, name: "Calendar User")
    event = CalendarEvent.create!(
      user: user,
      google_event_id: "abc123",
      start_time: Time.current,
      end_time: 1.hour.from_now
    )

    delete_called = false
    fake_service = Object.new
    fake_service.define_singleton_method(:delete_event) do |event_id|
      delete_called = true if event_id == "abc123"
      true
    end

    Collavre::GoogleCalendarService.stub(:new, ->(**_) { fake_service }) do
      event.destroy
    end

    assert_predicate event, :destroyed?
    assert delete_called, "Expected delete_event to be called"
  end

  test "does not call Google delete when google_event_id is nil" do
    user = User.create!(email: "calendar-user-local@example.com", password: TEST_PASSWORD, name: "Calendar User Local")
    event = CalendarEvent.create!(
      user: user,
      google_event_id: nil,
      start_time: Time.current,
      end_time: 1.hour.from_now
    )

    delete_called = false
    fake_service = Object.new
    fake_service.define_singleton_method(:delete_event) do |_event_id|
      delete_called = true
      true
    end

    Collavre::GoogleCalendarService.stub(:new, ->(**_) { fake_service }) do
      event.destroy
    end

    assert_predicate event, :destroyed?
    assert_not delete_called, "Expected delete_event NOT to be called for local-only event"
  end

  test "google_event_id.present? returns true when google_event_id present" do
    user = User.create!(email: "calendar-user-sync@example.com", password: TEST_PASSWORD, name: "Calendar Sync User")
    event = CalendarEvent.create!(
      user: user,
      google_event_id: "abc123",
      start_time: Time.current,
      end_time: 1.hour.from_now
    )

    assert event.google_event_id.present?
  end

  test "google_event_id.present? returns false when google_event_id nil" do
    user = User.create!(email: "calendar-user-nosync@example.com", password: TEST_PASSWORD, name: "Calendar NoSync User")
    event = CalendarEvent.create!(
      user: user,
      google_event_id: nil,
      start_time: Time.current,
      end_time: 1.hour.from_now
    )

    assert_not event.google_event_id.present?
  end
end
