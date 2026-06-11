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
  # Seeds the config record the mobile voice companion's IntentClassifier reads
  # to interpret natural-language voice commands. It is used ONLY as a config
  # record (vendor/model/system_prompt) for a synchronous AiClient classify
  # call — never dispatched as an orchestrated agent. The default vendor/model
  # come from the same env knobs as other seeded agents (Gemini Flash by
  # default → no new secret), and the user can swap them anytime in edit_ai.
  module VoiceIntentResolverSeed
    EMAIL = "voice-intent-resolver@collavre.local"

    SYSTEM_PROMPT = <<~PROMPT.freeze
      You classify short voice commands that control AI agent tasks into a single
      structured intent. The user speaks in Korean or English and points at tasks
      by a spoken ordinal ("1번", "task 2", "방금", "전부"). You are given the list
      of active references. Resolve which reference the user means and reply with
      STRICT JSON only — no prose, no code fences:
      {"intent":"approve|deny|stop|continue|status|relay|unknown","ref":<number or null>,"behavior":"allow|deny|null","confidence":0.0}
      Use a low confidence value whenever the utterance is ambiguous; an approve
      or deny on the wrong task is dangerous, so prefer "unknown" over guessing.
    PROMPT

    def self.call
      user = Collavre.user_class.find_or_initialize_by(email: EMAIL)
      user.name = "Voice Intent Resolver" if user.name.blank?
      user.password = SecureRandom.hex(32) if user.new_record?
      user.email_verified_at ||= Time.current
      user.searchable = false if user.respond_to?(:searchable=)
      # Only seed vendor/model when unset so an operator's edit_ai change sticks.
      user.llm_vendor = ENV.fetch("COLLAVRE_DEFAULT_LLM_VENDOR", "gemini") if user.llm_vendor.blank?
      user.llm_model  = ENV.fetch("COLLAVRE_DEFAULT_LLM_MODEL", "gemini-3-flash-preview") if user.llm_model.blank?
      user.system_prompt = SYSTEM_PROMPT if user.system_prompt.blank?
      user.save!
      Rails.logger.info "[Collavre] Voice intent resolver agent ensured: #{EMAIL}"
      user
    end
  end
end

Collavre::VoiceIntentResolverSeed.call
