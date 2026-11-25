# frozen_string_literal: true

require "time"

module Collavre
  module Quota
    class RetryTime
      MAX_DELAY = 14.days

      def self.parse(value, now: Time.current)
        return if value.nil? || value.to_s.bytesize > 128

        text = value.to_s.strip
        time = if text.match?(/\A\d+\z/)
          now + Integer(text, 10)
        else
          Time.httpdate(text)
        end
        time if time > now && time <= now + MAX_DELAY
      rescue ArgumentError, RangeError
        nil
      end

      # The Claude five-hour window reports a local clock and its timezone.
      def self.parse_claude_clock(value, now: Time.current)
        match = /\A(0?[1-9]|1[0-2]):([0-5]\d)\s*(am|pm)\s+\(([A-Za-z_]+(?:\/[A-Za-z_+-]+)+)\)\.?\z/i.match(value)
        return unless match && (zone = ActiveSupport::TimeZone[match[4]])

        hour = match[1].to_i % 12
        hour += 12 if match[3].casecmp?("pm")
        minute = match[2].to_i
        date = now.in_time_zone(zone).to_date
        reset = zone.local(date.year, date.month, date.day, hour, minute)
        if reset < now.beginning_of_minute
          tomorrow = date.tomorrow
          reset = zone.local(tomorrow.year, tomorrow.month, tomorrow.day, hour, minute)
        end
        [ reset, now ].max if reset <= now + 5.hours
      end
    end
  end
end
