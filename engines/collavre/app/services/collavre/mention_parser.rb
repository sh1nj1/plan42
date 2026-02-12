module Collavre
  # Centralized mention parsing and resolution.
  # All @mention logic should go through this module so changes
  # to the mention format only need to be made in one place.
  module MentionParser
    # Canonical mention: @name: (with colon separator)
    MENTION_PATTERN = /\A@([^:]+?):\s*/

    # Mention without colon: @name followed by whitespace
    MENTION_LOOSE_PATTERN = /\A@(\S+)\s+/

    # Extract the mentioned name from text (returns nil if no mention found)
    def self.extract_name(text)
      return nil if text.blank?

      match = text.match(MENTION_PATTERN) || text.match(MENTION_LOOSE_PATTERN)
      match ? match[1].strip : nil
    end

    # Find a User by case-insensitive name match
    def self.find_user_by_name(name)
      return nil if name.blank?

      User.where("LOWER(name) = ?", name.strip.downcase).first
    end

    # Extract mention and resolve to a User in one step
    def self.resolve_user(text)
      name = extract_name(text)
      name ? find_user_by_name(name) : nil
    end

    # Strip self-mention prefix from text (both @name: and @name formats)
    def self.strip_self_mention(text, agent_name)
      return text if text.blank? || agent_name.blank?

      escaped = Regexp.escape(agent_name)
      text
        .sub(/\A@#{escaped}:\s*/i, "")
        .sub(/\A@#{escaped}\s+/i, "")
    end
  end
end
