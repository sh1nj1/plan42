module Collavre
  module Comments
    class CalendarCommand
      def initialize(comment:, user:, url_helpers: Collavre::Engine.routes.url_helpers)
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
          return if args.blank?

          date_token, time_token, memo = parse_command_parts(args)
          return unless date_token || time_token

          parsed_date = parse_date_token(date_token)
          return if date_token.present? && parsed_date.blank?

          {
            date: parsed_date&.to_s,
            time: time_token,
            memo: memo
          }
        end
      end

      def command_body
        comment.content.to_s.strip.sub(/\A\S+/, "").strip
      end

      def parse_command_parts(args)
        if args.start_with?("@")
          match = args.match(/\A@(\d{2}:\d{2})(?:\s+(.*))?\z/)
          return unless match

          return [ nil, match[1], match[2] ]
        end

        match = args.match(/\A(\S+)?(?:@(\d{2}:\d{2}))?(?:\s+(.*))?\z/)
        return unless match

        [ match[1], match[2], match[3] ]
      end

      def parse_date_token(token)
        return if token.blank?

        today = Time.zone.today
        token = token.strip

        return today if token.match?(/\Atoday\z/i)
        return today + 1.day if token.match?(/\Atomorrow\z/i)

        interval_match = token.match(/\A\+(\d+)(days?|weeks?|months?|years?)\z/i)
        if interval_match
          amount = interval_match[1].to_i
          unit = interval_match[2].downcase
          return today + amount.days if unit.start_with?("day")
          return today + amount.weeks if unit.start_with?("week")
          return today.advance(months: amount) if unit.start_with?("month")
          return today.advance(years: amount) if unit.start_with?("year")
        end

        weekday_match = token.match(/\A\+(\d+)?(mon|tue|wed|thu|fri|sat|sun|[월화수목금토일])\z/i)
        if weekday_match
          count = weekday_match[1].present? ? weekday_match[1].to_i : 1
          return next_weekday(today, weekday_index(weekday_match[2]), count)
        end

        Date.iso8601(token) if token.match?(/\A\d{4}-\d{2}-\d{2}\z/)
      end

      def weekday_index(token)
        case token.to_s.downcase
        when "mon", "월" then 1
        when "tue", "화" then 2
        when "wed", "수" then 3
        when "thu", "목" then 4
        when "fri", "금" then 5
        when "sat", "토" then 6
        when "sun", "일" then 0
        end
      end

      def next_weekday(base_date, target_wday, count)
        days_until = (target_wday - base_date.wday) % 7
        days_until = 7 if days_until.zero?
        base_date + days_until + (count - 1) * 7
      end

      def google_login?
        user&.google_refresh_token.present?
      end

      def create_event
        data = parsed_args
        return unless data
        return I18n.t("collavre.comments.calendar_command.google_login_required") unless google_login?

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

        I18n.t("collavre.comments.calendar_command.event_created", url: event.html_link)
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
end
