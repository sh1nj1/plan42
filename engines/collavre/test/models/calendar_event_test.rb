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
end
