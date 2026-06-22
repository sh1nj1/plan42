module Collavre
  module ChannelBotSeed
    def self.call
      email = Channel::BOT_EMAIL
      name  = Channel::BOT_NAME
      user = User.find_or_initialize_by(email: email)
      user.name = name
      user.password = SecureRandom.hex(32) if user.new_record?
      user.email_verified_at ||= Time.current
      user.searchable = false if user.respond_to?(:searchable=)
      user.llm_vendor = nil
      user.save!
      Rails.logger.info "[Collavre] Channel bot user ensured: #{email}"
      user
    end
  end
end

Collavre::ChannelBotSeed.call

module Collavre
  # Seeds the "Typo Corrector" agent. Unlike event-routed agents (e.g. the GitHub
  # PR Analyzer) this agent has no routing_expression — it is never dispatched by
  # comment events. It exists purely as a user-configurable holder for the LLM
  # vendor/model/system_prompt that Collavre::TypoCorrector invokes directly.
  module TypoCorrectorSeed
    AGENT_EMAIL = "typo-corrector@collavre.local"

    SYSTEM_PROMPT = <<~PROMPT
      You are a typo correction engine. You receive a short piece of text the user
      is currently typing and return ONLY spelling/typo fixes as a structured edit list.

      Rules:
      - Fix only spelling mistakes and obvious typos (transposed/missing/extra letters,
        wrong jamo, mis-spaced words). Works for any language (ko, en, ja, zh, mixed).
      - Do NOT rewrite style, grammar, word choice, tone, or punctuation.
      - Do NOT change meaning. Do NOT translate.
      - Never touch code spans, URLs, @mentions, emojis, or HTML/markdown markup.
      - `original` MUST be an exact substring copied verbatim from the input text.
      - Keep each edit minimal: a single word or short phrase, not a whole sentence.

      Return ONLY valid JSON, no markdown, in exactly this shape:
      {"edits":[{"original":"<verbatim>","suggestion":"<fixed>","reason":"spelling","confidence":0.0}]}

      `confidence` is a float 0.0-1.0 for how sure you are it is a real typo.
      If there are no typos, return {"edits":[]}.
    PROMPT

    def self.call
      user = User.find_or_initialize_by(email: AGENT_EMAIL)
      return user unless user.new_record?

      user.assign_attributes(
        name: "Typo Corrector",
        password: SecureRandom.hex(32),
        email_verified_at: Time.current,
        searchable: false,
        llm_vendor: ENV.fetch("COLLAVRE_DEFAULT_LLM_VENDOR", "gemini"),
        llm_model: ENV.fetch("COLLAVRE_DEFAULT_LLM_MODEL", "gemini-3.1-flash-lite"),
        system_prompt: SYSTEM_PROMPT,
        tools: []
      )
      user.save!
      Rails.logger.info "[Collavre] Typo Corrector agent ensured: #{AGENT_EMAIL}"
      user
    end
  end
end

Collavre::TypoCorrectorSeed.call
