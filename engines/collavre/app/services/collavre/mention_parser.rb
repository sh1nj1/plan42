module Collavre
  # Centralized mention parsing and resolution.
  # All @mention logic should go through this module so changes
  # to the mention format only need to be made in one place.
  module MentionParser
    # Canonical mention: @name: (with colon separator)
    # Matches at start of text or after whitespace/newline
    MENTION_PATTERN = /(?:\A|(?<=\s))@([^:]+?):\s*/

    # Mention without colon: @name followed by whitespace (start-of-text only
    # to avoid false positives like email addresses)
    MENTION_LOOSE_PATTERN = /\A@(\S+)\s+/

    # Scan pattern: finds all @name: mentions anywhere in text
    MENTION_SCAN_PATTERN = /(?:^|\s)@([^:]+?):/

    # Extract the first mentioned name from text (returns nil if no mention found)
    def self.extract_name(text)
      return nil if text.blank?

      match = text.match(MENTION_PATTERN) || text.match(MENTION_LOOSE_PATTERN)
      match ? match[1].strip : nil
    end

    # Extract all mentioned names from text
    def self.extract_all_names(text)
      return [] if text.blank?

      text.scan(MENTION_SCAN_PATTERN).flatten.map(&:strip).uniq
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

    # Resolve all mentioned users from text (finds mentions anywhere)
    def self.resolve_all_users(text)
      extract_all_names(text).filter_map { |name| find_user_by_name(name) }.uniq
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
