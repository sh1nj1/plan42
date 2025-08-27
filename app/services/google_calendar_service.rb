require "google/apis/calendar_v3"
require "googleauth"

class GoogleCalendarService
  def initialize(user:)
    @user = user
    @service = Google::Apis::CalendarV3::CalendarService.new
    @service.client_options.application_name = "Collavre"
    @service.authorization = user_credentials
  end

  # Creates a Google Calendar event.
  # Optional params supported: location, recurrence (array), attendees (array of emails or attendee hashes),
  # reminders (hash: { use_default: true/false, overrides: [{ method: 'email'|'popup', minutes: Integer }, ...] })
  def create_event(
    calendar_id: "primary",
    start_time:,
    end_time:,
    summary:,
    description: nil,
    timezone: "Asia/Seoul",
    location: nil,
    recurrence: nil,
    attendees: nil,
    reminders: nil,
    all_day: false
  )
    event_args = { summary: summary, description: description }

    if all_day
      # All-day events must use date (no time or timezone). End date is exclusive per Google Calendar API.
      start_date = start_time.to_date
      end_date_exclusive = end_time.to_date + 1
      event_args[:start] = { date: start_date.iso8601 }
      event_args[:end]   = { date: end_date_exclusive.iso8601 }
    else
      event_args[:start] = { date_time: start_time.iso8601, time_zone: timezone }
      event_args[:end]   = { date_time: end_time.iso8601,   time_zone: timezone }
    end

    event_args[:location] = location if location.present?
    event_args[:recurrence] = recurrence if recurrence.present?

    if attendees.present?
      event_args[:attendees] = Array(attendees).map do |a|
        if a.is_a?(String)
          Google::Apis::CalendarV3::EventAttendee.new(email: a)
        elsif a.is_a?(Hash)
          # Support keys like :email, :response_status, etc.
          Google::Apis::CalendarV3::EventAttendee.new(**a.symbolize_keys)
        else
          nil
        end
      end.compact
    end

    if reminders.present?
      use_default = reminders[:use_default]
      overrides = Array(reminders[:overrides]).map do |r|
        # IMPORTANT: Ruby client uses method_prop instead of method
        meth = r[:method] || r[:method_prop]
        mins = r[:minutes]
        Google::Apis::CalendarV3::EventReminder.new(method_prop: meth, minutes: mins)
      end
      event_args[:reminders] = Google::Apis::CalendarV3::Event::Reminders.new(use_default: !!use_default, overrides: overrides)
    end

    event = Google::Apis::CalendarV3::Event.new(**event_args)

    if @service.authorization.scope.include?(Google::Apis::CalendarV3::AUTH_CALENDAR_APP_CREATED)
      @user.calendar_id ||= create_app_calendar
      calendar_id = @user.calendar_id
    end
    @service.insert_event(calendar_id, event)
  rescue Google::Apis::ClientError => e
    # Surface helpful error info to aid debugging 400 errors
    Rails.logger.error("Google Calendar insert_event 4xx: #{e.class} #{e.status_code} - #{e.message} body=#{e.body}")
    raise
  end

  def list_calendars
    @service.list_calendar_lists.items.map { |c| [ c.summary, c.id ] }.to_h
  end

  private

  def user_credentials
    Google::Auth::UserRefreshCredentials.new(
      client_id:     Rails.application.credentials.dig(:google, :client_id),
      client_secret: Rails.application.credentials.dig(:google, :client_secret),
      scope:         [ Google::Apis::CalendarV3::AUTH_CALENDAR_APP_CREATED ],
      refresh_token: @user.google_refresh_token
    ).tap(&:fetch_access_token!)
  end

  def create_app_calendar
    calendar = @service.insert_calendar(Google::Apis::CalendarV3::Calendar.new(summary: @service.client_options.application_name))
    # save calendar id to user profile
    @user.update(calendar_id: calendar.id)
    calendar.id
  rescue Google::Apis::ClientError => e
    # Surface helpful error info to aid debugging 400 errors
    Rails.logger.error("Google Calendar create_calendar 4xx: #{e.class} #{e.status_code} - #{e.message} body=#{e.body}")
    raise
  end

  public

  # Ensure user's app calendar exists if the token has calendar.app.created scope.
  # Returns the calendar_id if created/found, otherwise nil.
  def ensure_app_calendar!
    if @service.authorization.scope.include?(Google::Apis::CalendarV3::AUTH_CALENDAR_APP_CREATED)
      if @user.calendar_id.nil?
        @user.calendar_id = create_app_calendar
      else
        calendar = @service.get_calendar(@user.calendar_id)
        if calendar.id != @user.calendar_id
          @user.calendar_id = create_app_calendar
        end
      end
    end
    @user.calendar_id
  end
end
