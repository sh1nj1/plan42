module CollavreSlack
  module EmojiMapping
    # Bidirectional emoji mapping between Slack names and Unicode
    MAPPINGS = {
      # Thumbs
      "thumbsup" => "\u{1F44D}",
      "+1" => "\u{1F44D}",
      "thumbsdown" => "\u{1F44E}",
      "-1" => "\u{1F44E}",
      # Hearts
      "heart" => "\u{2764}",
      "blue_heart" => "\u{1F499}",
      "green_heart" => "\u{1F49A}",
      "yellow_heart" => "\u{1F49B}",
      # Faces
      "grinning" => "\u{1F600}",
      "smiley" => "\u{1F603}",
      "smile" => "\u{1F604}",
      "grin" => "\u{1F601}",
      "joy" => "\u{1F602}",
      "sweat_smile" => "\u{1F605}",
      "laughing" => "\u{1F606}",
      "wink" => "\u{1F609}",
      "blush" => "\u{1F60A}",
      "heart_eyes" => "\u{1F60D}",
      "thinking_face" => "\u{1F914}",
      "cry" => "\u{1F622}",
      "sob" => "\u{1F62D}",
      "rage" => "\u{1F621}",
      "angry" => "\u{1F620}",
      # Hands
      "clap" => "\u{1F44F}",
      "raised_hands" => "\u{1F64C}",
      "pray" => "\u{1F64F}",
      "wave" => "\u{1F44B}",
      "ok_hand" => "\u{1F44C}",
      "v" => "\u{270C}",
      # Objects
      "tada" => "\u{1F389}",
      "fire" => "\u{1F525}",
      "rocket" => "\u{1F680}",
      "star" => "\u{2B50}",
      "100" => "\u{1F4AF}",
      "eyes" => "\u{1F440}",
      # Symbols
      "white_check_mark" => "\u{2705}",
      "x" => "\u{274C}",
      "heavy_check_mark" => "\u{2714}",
      "warning" => "\u{26A0}",
      "question" => "\u{2753}",
      "exclamation" => "\u{2757}"
    }.freeze

    # Reverse mapping (Unicode -> Slack name)
    UNICODE_TO_SLACK = MAPPINGS.each_with_object({}) do |(name, unicode), hash|
      hash[unicode] = name unless hash.key?(unicode)
    end.freeze

    # Convert Slack emoji name to Unicode
    def self.to_unicode(slack_name)
      return nil if slack_name.blank?
      MAPPINGS[slack_name.to_s] || ":#{slack_name}:"
    end

    # Convert Unicode emoji to Slack name
    def self.to_slack(emoji)
      return "thumbsup" if emoji.blank?

      str = emoji.to_s.strip.gsub(/^:+|:+$/, "")

      # Check direct mapping
      return UNICODE_TO_SLACK[str] if UNICODE_TO_SLACK.key?(str)

      # Check if it's already a Slack name
      return str if MAPPINGS.key?(str)

      # Handle +1/-1 aliases
      return "thumbsup" if str == "+1"
      return "thumbsdown" if str == "-1"

      # If still contains non-ASCII, it's an unmapped emoji
      if str.match?(/[^\x00-\x7F]/)
        Rails.logger.warn("[CollavreSlack] Unmapped emoji: #{str.inspect}")
        return "thumbsup"
      end

      str
    end
  end
end
