module Collavre
  # Server-side typo correction. Sends the text the user is typing to an LLM and
  # returns a validated *structured edit list* — never a rewritten string. Each
  # edit is {original, suggestion, reason, confidence}. Validation rejects anything
  # that is not a small, in-place spelling fix (style rewrites, hallucinated spans,
  # edits inside code/URLs/mentions), so the UI can trust every returned edit.
  class TypoCorrector
    AGENT_EMAIL = "typo-corrector@collavre.local"

    # Reject "corrections" that are really rewrites: an edit is kept only when the
    # original is short and the suggestion is within this edit distance of it.
    MAX_ORIGINAL_LENGTH = 40
    MIN_EDIT_DISTANCE_CAP = 2
    EDIT_DISTANCE_RATIO = 0.4

    FALLBACK_SYSTEM_PROMPT = <<~PROMPT.freeze
      You are a typo correction engine. Fix only spelling mistakes and obvious typos,
      never style, grammar or meaning, in any language. `original` must be an exact
      substring of the input. Return ONLY JSON:
      {"edits":[{"original":"x","suggestion":"y","reason":"spelling","confidence":0.0}]}
    PROMPT

    def initialize(client: nil)
      @client = client
    end

    # Returns an Array of Hashes with string keys: "original", "suggestion",
    # "reason", "confidence". Empty array on blank input or LLM/parse failure.
    def correct(text)
      text = text.to_s
      return [] if text.strip.blank?

      response = client.chat([
        { role: :user, parts: [ { text: "Text:\n#{text}" } ] }
      ])

      edits = parse_response(response)
      validate(edits, text)
    end

    private

    def client
      @client ||= build_client
    end

    def build_client
      agent = Collavre.user_class.find_by(email: AGENT_EMAIL)
      AiClient.new(
        vendor: agent&.llm_vendor.presence || ENV.fetch("COLLAVRE_DEFAULT_LLM_VENDOR", "gemini"),
        model: agent&.llm_model.presence || ENV.fetch("COLLAVRE_DEFAULT_LLM_MODEL", "gemini-3.1-flash-lite"),
        system_prompt: agent&.system_prompt.presence || FALLBACK_SYSTEM_PROMPT,
        llm_api_key: agent&.llm_api_key,
        gateway_url: agent&.gateway_url,
        # Runs on debounced typing of *unsubmitted* text — never persist the draft
        # to ActivityLog (RubyLlmInteractionLogger writes `messages` there).
        log_interactions: false
      )
    end

    def parse_response(content)
      return [] if content.blank?

      cleaned = content.gsub(/^```json\s*/, "").gsub(/\s*```$/, "").strip
      parsed = JSON.parse(cleaned)
      edits = parsed.is_a?(Hash) ? parsed["edits"] : parsed
      edits.is_a?(Array) ? edits : []
    rescue JSON::ParserError => e
      Rails.logger.warn("[TypoCorrector] JSON parse error: #{e.message}. Content: #{content.to_s.truncate(200)}")
      []
    end

    def validate(edits, text)
      skip_ranges = skip_ranges(text)
      seen = {}

      edits.filter_map do |edit|
        next unless edit.is_a?(Hash)

        original = edit["original"].to_s
        suggestion = edit["suggestion"].to_s
        next if original.empty? || suggestion.empty? || original == suggestion
        next if original.length > MAX_ORIGINAL_LENGTH

        # `original` must appear verbatim in the text, outside any skip region
        # (code/URL/mention/markup). We return the offset of that first *valid*
        # occurrence so the client anchors there — otherwise the client's own
        # left-to-right search would bind to an earlier occurrence sitting inside
        # a protected span and edit it (a markdown-canonical/code-safety hole).
        offset = first_offset_outside_skip_ranges(text, original, skip_ranges)
        next if offset.nil?

        # Reject big rewrites — keep only minimal in-place fixes.
        cap = [ MIN_EDIT_DISTANCE_CAP, (original.length * EDIT_DISTANCE_RATIO).ceil ].max
        next if levenshtein(original, suggestion) > cap

        key = [ original, suggestion ]
        next if seen[key]
        seen[key] = true

        {
          "original" => original,
          "suggestion" => suggestion,
          "reason" => edit["reason"].presence || "spelling",
          "confidence" => clamp_confidence(edit["confidence"]),
          # Emit the offset in UTF-16 code units, the coordinate space JS string
          # indexing uses. A Ruby character index would be off by one per astral
          # character (emoji, etc.) before the typo, so the client's substring
          # check at `offset` would fail and fall back to indexOf — which can bind
          # to a protected occurrence the server already excluded.
          "offset" => utf16_offset(text, offset)
        }
      end
    end

    def clamp_confidence(value)
      return 0.5 if value.nil?

      Float(value).clamp(0.0, 1.0)
    rescue ArgumentError, TypeError
      0.5
    end

    # Character ranges that must never be edited: fenced code, inline code, URLs,
    # @mentions, HTML tags, and markdown-canonical <span style> color fragments.
    def skip_ranges(text)
      ranges = []
      patterns = [
        /```.*?```/m,             # fenced code blocks
        /`[^`]*`/,                # inline code
        %r{https?://\S+},         # URLs
        /@[^\s@]+/,               # @mentions
        # `[^<>]` (not just `[^>]`) keeps this linear: a stray run of "<<<<" can't
        # make scan re-walk the tail from every "<" (CodeQL polynomial-ReDoS).
        /<[^<>]+>/                # HTML / span-style markup
      ]
      patterns.each do |pattern|
        text.scan(pattern) { ranges << Regexp.last_match.offset(0) }
      end
      ranges
    end

    # First character offset where `needle` occurs entirely outside every skip
    # range, or nil if every occurrence overlaps a protected span.
    def first_offset_outside_skip_ranges(text, needle, skip_ranges)
      pos = 0
      while (idx = text.index(needle, pos))
        finish = idx + needle.length
        inside = skip_ranges.any? { |(s, e)| idx < e && finish > s }
        return idx unless inside

        pos = idx + 1
      end
      nil
    end

    # Convert a Ruby character index into a UTF-16 code-unit offset (JS string
    # coordinates). Characters outside the BMP count as two code units in JS.
    def utf16_offset(text, char_index)
      text[0, char_index].to_s.encode("UTF-16LE").bytesize / 2
    rescue Encoding::UndefinedConversionError, Encoding::InvalidByteSequenceError
      char_index
    end

    # Iterative Levenshtein distance.
    def levenshtein(a, b)
      a = a.chars
      b = b.chars
      prev = (0..b.length).to_a
      a.each_with_index do |ac, i|
        curr = [ i + 1 ]
        b.each_with_index do |bc, j|
          cost = ac == bc ? 0 : 1
          curr << [ curr[j] + 1, prev[j + 1] + 1, prev[j] + cost ].min
        end
        prev = curr
      end
      prev.last
    end
  end
end
