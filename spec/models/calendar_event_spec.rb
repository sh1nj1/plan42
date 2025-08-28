require 'rails_helper'

describe CalendarEvent, type: :model do
  it 'deletes Google Calendar event when destroyed' do
    user = User.create!(email: 'user@example.com', password: 'pw', name: 'User')
    event = CalendarEvent.create!(user: user, google_event_id: 'abc123', start_time: Time.current, end_time: 1.hour.from_now)

    service = instance_double(GoogleCalendarService)
    expect(GoogleCalendarService).to receive(:new).with(user: user).and_return(service)
    expect(service).to receive(:delete_event).with('abc123')

    event.destroy
  end
end
