require "google/apis/calendar_v3"

class GoogleCalendarService
  def initialize
    @service = Google::Apis::CalendarV3::CalendarService.new
    @service.authorization = authorization
  end

  def create_event(calendar_id:, start_time:, end_time:, summary:)
    event = Google::Apis::CalendarV3::Event.new(
      summary: summary,
      start: build_event_time(start_time),
      end: build_event_time(end_time)
    )
    @service.insert_event(calendar_id, event)
  end

  private

  def authorization
    Google::Auth.get_application_default([ Google::Apis::CalendarV3::AUTH_CALENDAR ])
  end

  def build_event_time(time)
    if time.is_a?(Date)
      Google::Apis::CalendarV3::EventDateTime.new(date: time.iso8601)
    else
      Google::Apis::CalendarV3::EventDateTime.new(date_time: time.iso8601, time_zone: time.zone.name)
    end
  end
end
