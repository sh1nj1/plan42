module Comments
  class CalendarCommand
    def initialize(comment:, user:, url_helpers: Rails.application.routes.url_helpers)
      @comment = comment
      @user = user
      @creative = comment.creative.effective_origin
      @url_helpers = url_helpers
    end

    def call
      return unless calendar_command?

      create_event
    rescue StandardError => e
      Rails.logger.error("Calendar command failed: #{e.message}")
      e.message
    end

    private

    attr_reader :comment, :user, :creative, :url_helpers

    COMMAND_PATTERN = /\A\/(?:calendar|cal)\b/i.freeze

    def calendar_command?
      comment.content.to_s.strip.match?(COMMAND_PATTERN)
    end

    def parsed_args
      @parsed_args ||= begin
        args = command_body
        args = args.sub(/\A(today)\b/i, Time.zone.today.to_s) if args.match?(/\Atoday\b/i)
        match = args.match(/\A(?:(\d{4}-\d{2}-\d{2}))?(?:@(\d{2}:\d{2}))?(?:\s+(.*))?\z/)
        return unless match
        return unless match[1].present? || match[2].present?

        {
          date: match[1],
          time: match[2],
          memo: match[3]
        }
      end
    end

    def command_body
      comment.content.to_s.strip.sub(/\A\S+/, "").strip
    end

    def create_event
      data = parsed_args
      return unless data

      timezone = Time.zone
      start_time, end_time = calculate_times(timezone, data[:date], data[:time])
      summary = build_summary(data[:memo])
      calendar_id = comment.user&.calendar_id.presence || "primary"

      event = GoogleCalendarService.new(user: user).create_event(
        calendar_id: calendar_id,
        start_time: start_time,
        end_time: end_time,
        summary: summary,
        description: event_description,
        timezone: timezone.tzinfo.name,
        all_day: data[:time].nil?,
        creative: creative
      )

      I18n.t("comments.calendar_command.event_created", url: event.html_link)
    end

    def calculate_times(timezone, date_str, time_str)
      if time_str
        date_for_time = date_str.presence || timezone.today.to_s
        start_time = timezone.parse("#{date_for_time} #{time_str}")
        [ start_time, start_time ]
      else
        start_time = Date.parse(date_str.presence || timezone.today.to_s)
        [ start_time, start_time ]
      end
    end

    def build_summary(memo)
      return memo if memo.present?

      base_summary = creative.effective_description(false, false)
      base_summary
    end

    def event_description
      defaults = Rails.application.config.action_mailer.default_url_options || {}
      url_helpers.creative_url(creative, defaults.merge(comment_id: comment.id))
    end
  end
end
