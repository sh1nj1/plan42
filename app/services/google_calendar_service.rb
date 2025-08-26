require "google/apis/calendar_v3"
require "googleauth"

class GoogleCalendarService
  def initialize(user:)
    @user = user
    @service = Google::Apis::CalendarV3::CalendarService.new
    @service.authorization = user_credentials
  end

  def create_event(calendar_id: "primary", start_time:, end_time:, summary:, description: nil, timezone: "Asia/Seoul")
    event = Google::Apis::CalendarV3::Event.new(
      summary: summary,
      description: description,
      start: Google::Apis::CalendarV3::EventDateTime.new(date_time: start_time.iso8601, time_zone: timezone),
      end:   Google::Apis::CalendarV3::EventDateTime.new(date_time: end_time.iso8601,   time_zone: timezone)
    )
    @service.insert_event(calendar_id, event)
  end

  def list_calendars
    @service.list_calendar_lists.items.map { |c| [ c.summary, c.id ] }.to_h
  end

  private

  def user_credentials
    Google::Auth::UserRefreshCredentials.new(
      client_id:     Rails.application.credentials.dig(:google, :client_id),
      client_secret: Rails.application.credentials.dig(:google, :client_secret),
      scope:         [ Google::Apis::CalendarV3::AUTH_CALENDAR ],
      redirect_uri:  nil,
      additional_parameters: { "access_type" => "offline" },
      refresh_token: @user.google_refresh_token
    ).tap(&:fetch_access_token!)
  end
end
