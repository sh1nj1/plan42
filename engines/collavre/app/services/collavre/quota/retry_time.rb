# frozen_string_literal: true

require "time"

module Collavre
  module Quota
    # Only protocol timestamps are trusted. Human reset messages can omit their
    # date or timezone and must use bounded probes instead of guessing.
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
    end
  end
end
