# frozen_string_literal: true

module Collavre
  module Mobile
    # The LLM fallback for the hybrid resolver. It loads a SEEDED ai_agent User
    # (voice-intent-resolver@collavre.local) purely as a CONFIG RECORD — reading
    # its llm_vendor/llm_model/system_prompt/llm_api_key — and calls AiClient
    # SYNCHRONOUSLY for structured intent classification. It is NEVER dispatched
    # through the heavy Comment→Dispatcher→Orchestrator→Task path: that would put
    # full agent orchestration on the voice hot path. The user can swap the
    # vendor/model anytime in the existing edit_ai UI; no model id is hardcoded.
    #
    # Returns a Result, or nil on any failure (missing agent, timeout, bad JSON)
    # so the caller degrades gracefully to the deterministic grammar result.
    class IntentClassifier
      RESOLVER_EMAIL = "voice-intent-resolver@collavre.local"

      Result = Struct.new(:intent, :ref, :behavior, :confidence, :raw, keyword_init: true)

      def initialize(locale:, refs: [])
        @locale = (locale.presence || I18n.default_locale).to_s
        @refs = refs
      end

      def self.resolver_agent
        Collavre::User.ai_agents.find_by(email: RESOLVER_EMAIL)
      end

      def classify(text)
        agent = self.class.resolver_agent
        return nil unless agent&.llm_vendor.present?

        client = Collavre::AiClient.new(
          vendor: agent.llm_vendor,
          model: agent.llm_model,
          system_prompt: agent.system_prompt.presence || default_system_prompt,
          llm_api_key: agent.llm_api_key,
          gateway_url: agent.gateway_url
        )
        response = client.chat([ { role: :user, parts: [ { text: prompt_for(text) } ] } ])
        parse(response)
      rescue StandardError => e
        Rails.logger.warn("[Mobile::IntentClassifier] degraded: #{e.class} #{e.message}")
        nil
      end

      private

      def prompt_for(text)
        ref_lines = @refs.map { |r| "##{r.ref_number} (#{r.kind}): #{r.label}" }
        <<~PROMPT
          Locale: #{@locale}
          User said: "#{text}"

          Active references the user may point at:
          #{ref_lines.presence&.join("\n") || "(none)"}

          Classify into one intent and resolve which reference it points at.
          Reply with STRICT JSON only, no prose:
          {"intent":"approve|deny|stop|continue|status|relay|unknown","ref":<number or null>,"behavior":"allow|deny|null","confidence":0.0}
          - "approve"/"deny": a decision on an approval reference (behavior allow/deny).
          - "stop"/"continue": control an agent session reference.
          - "status": user asks about progress (ref optional).
          - "relay": a free-form message to pass to the agent verbatim.
          - "unknown": cannot tell. Use low confidence when unsure.
        PROMPT
      end

      def parse(response)
        return nil if response.blank?

        json = response[/\{.*\}/m]
        return nil unless json

        data = JSON.parse(json)
        Result.new(
          intent: data["intent"].to_s.presence,
          ref: normalize_ref(data["ref"]),
          behavior: data["behavior"].to_s.presence,
          confidence: (data["confidence"] || 0.0).to_f,
          raw: response
        )
      rescue JSON::ParserError
        nil
      end

      def normalize_ref(value)
        return nil if value.nil?
        return value.to_i if value.is_a?(Numeric) || value.to_s.match?(/\A\d+\z/)

        value.to_s
      end

      def default_system_prompt
        "You classify short voice commands that control AI agent tasks into " \
          "structured intents. You always answer with strict JSON only."
      end
    end
  end
end
