module Collavre
  # Centralized mention parsing and resolution.
  # All @mention logic should go through this module so changes
  # to the mention format only need to be made in one place.
  module MentionParser
    # Characters allowed before @ in mentions (besides start-of-text)
    MENTION_PREFIX_CHARS = /[\s:.,;\n\r]/

    # The name part of a canonical mention. Spaces are allowed (agents are named
    # things like "GitHub PR Analyzer"), but line breaks are not: a lazy
    # "anything up to the next colon" would let a colon-free mention on one line
    # swallow the rest of the line plus the next line's "@", collapsing two
    # mentions into one unresolvable name. At signs remain valid because user
    # names have no corresponding model restriction.
    MENTION_NAME = /[^:\n\r]+?/

    # Canonical mention: @name: (with colon separator)
    # Matches at start of text or after whitespace/punctuation/newline
    MENTION_PATTERN = /(?:\A|(?<=#{MENTION_PREFIX_CHARS}))@(#{MENTION_NAME}):\s*/

    # Mention without colon: @name followed by whitespace (start-of-text only
    # to avoid false positives like email addresses). The name excludes ":" so
    # a canonical "@name:" is never also read as the loose name "name:".
    MENTION_LOOSE_PATTERN = /\A@([^:\s]+)\s+/

    # Scan pattern: finds all @name: mentions anywhere in text
    MENTION_SCAN_PATTERN = /(?:^|(?<=#{MENTION_PREFIX_CHARS}))@(#{MENTION_NAME}):/

    # A canonical mention occupying start-of-text, where the loose form would
    # otherwise also match and truncate the name at its first space.
    MENTION_CANONICAL_AT_START = /\A@#{MENTION_NAME}:/

    # Extract the first mentioned name from text (returns nil if no mention found)
    def self.extract_name(text)
      extract_all_names(text).first
    end

    # Extract all mentioned names from text, in the order they appear.
    def self.extract_all_names(text)
      return [] if text.blank?

      names = text.scan(MENTION_SCAN_PATTERN).flatten

      # The loose form only ever matches at start-of-text, so whatever it finds
      # precedes every canonical mention — unless a canonical one already owns
      # that position, in which case it has the more complete name.
      unless text.match?(MENTION_CANONICAL_AT_START)
        loose = text.match(MENTION_LOOSE_PATTERN)
        names.unshift(loose[1]) if loose
      end

      names.map(&:strip).reject(&:blank?).uniq
    end

    # Find a User by case-insensitive name match
    def self.find_user_by_name(name)
      return nil if name.blank?

      User.where("LOWER(name) = ?", name.strip.downcase).first
    end

    # Extract mention and resolve to a User in one step
    def self.resolve_user(text)
      resolve_all_users(text).first
    end

    # Resolve all mentioned users from text, in mention order.
    #
    # One lookup for the whole body, not one per name: a comment carries as many
    # mentions as its author typed, and this runs inside the synchronous
    # after-commit dispatch, so a per-name query would put the mention count
    # directly on the critical path. Order comes back from the mention list
    # rather than from the rows, which arrive in whatever order the database
    # picked.
    def self.resolve_all_users(text)
      keys = extract_all_names(text).map { |name| name.strip.downcase }.uniq
      return [] if keys.empty?

      # Ordered by id, and first-wins, so two names differing only in case
      # resolve to the same row find_user_by_name would have returned.
      by_key = User.where("LOWER(name) IN (?)", keys).order(:id)
                   .each_with_object({}) { |user, acc| acc[user.name.to_s.downcase] ||= user }

      keys.filter_map { |key| by_key[key] }
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
