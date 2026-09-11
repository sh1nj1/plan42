# frozen_string_literal: true

module Collavre
  module Topics
    # A character cap and the unit it is measured in.
    #
    # The two travel together because neither is meaningful alone. A cap of
    # 40,000 buys a different amount of conversation depending on whether the
    # response is a markdown transcript or a JSON object, and budgeting in one
    # unit while emitting the other is exactly how a cap gets exceeded by half
    # again. Keeping them in one object means a caller cannot supply a cap and
    # forget to say what it counts.
    class CharBudget
      FORMATS = %w[markdown json].freeze
      DEFAULT_FORMAT = "markdown"

      # Markdown's per-message overhead: the id, the ISO-8601 timestamp, the
      # author separator and two newlines. Measured rather than guessed —
      # content-only accounting hands this out for free, and a few hundred short
      # messages is then an entire budget spent off the books.
      ENVELOPE_CHARS = 36

      # Markdown tags an AI author with a " (agent)" suffix on its byline. Eight
      # characters is nothing on one message and a page's worth on a stretch of
      # short agent turns, which is exactly the shape a busy topic has — and it
      # is more than the margin the per-topic reserve leaves to absorb it.
      AGENT_SUFFIX_CHARS = " (agent)".length

      attr_reader :chars, :format

      def self.normalize_format(value)
        FORMATS.include?(value.to_s) ? value.to_s : DEFAULT_FORMAT
      end

      def initialize(chars: nil, format: DEFAULT_FORMAT)
        @chars = chars
        @format = self.class.normalize_format(format)
      end

      def unlimited? = @chars.nil?

      def json? = @format == "json"

      def with(chars:) = self.class.new(chars: chars, format: @format)

      # What emitting this message costs, which is a property of the format
      # rather than of the record.
      #
      # json is measured against the serialized form instead of estimated from
      # it: the field names are a fixed ~120 characters the prose never sees,
      # and the escaping ratio varies with the message, so no constant tracks
      # both. The trailing character is the comma that joins it to the next one.
      def cost(message)
        return message.to_json.length + 1 if json?

        ENVELOPE_CHARS + message[:content].to_s.length + message[:clip_notice].to_s.length +
          message[:author].to_s.length +
          (message[:agent] ? AGENT_SUFFIX_CHARS : 0)
      end

      # Whether a message of this cost still fits alongside what has been spent.
      # Takes the cost rather than the message so the caller can charge what it
      # measured instead of serializing the same message twice.
      #
      # Deciding before keeping is the point: appending first and checking
      # afterwards let a message wider than the entire cap through untouched.
      def fits?(cost, spent: 0) = unlimited? || (spent + cost) <= @chars
    end
  end
end
