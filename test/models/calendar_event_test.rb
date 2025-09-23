require "test_helper"

class CalendarEventTest < ActiveSupport::TestCase
  test "deletes Google Calendar event when destroyed" do
    user = User.create!(email: "calendar-user@example.com", password: "secret", name: "Calendar User")
    event = CalendarEvent.create!(
      user: user,
      google_event_id: "abc123",
      start_time: Time.current,
      end_time: 1.hour.from_now
    )

    service = Minitest::Mock.new
    service.expect(:delete_event, true, [ "abc123" ])

    GoogleCalendarService.stub(:new, service) do
      event.destroy
    end

    assert_predicate event, :destroyed?
    assert_mock service
  end
end
