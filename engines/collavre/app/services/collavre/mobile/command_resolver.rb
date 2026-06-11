# frozen_string_literal: true

module Collavre
  module Mobile
    # Hybrid speech→intent resolver.
    #
    #  ① Deterministic grammar fast-path for the safety-critical, most-frequent
    #     bounded commands ("N번 승인/거절/멈춰/계속"): regex + number normalization,
    #     instant and 100% predictable — no model, no latency, no misrecognition
    #     risk on the dangerous allow/deny verbs.
    #  ② On a miss, fall back to the seeded ai_agent (IntentClassifier) for the
    #     natural variants / aliases ("방금/마지막/전부/OpenClaw 작업").
    #  ③ Low confidence ⇒ intent stays as classified but the controller asks for
    #     confirmation instead of acting (prevents a misheard word from executing
    #     an irreversible decision).
    class CommandResolver
      Resolution = Struct.new(:intent, :ref, :behavior, :confidence, :source, keyword_init: true)

      # Korean & English number words → integer. Digits handled separately.
      NUMBER_WORDS = {
        "하나" => 1, "한" => 1, "일" => 1, "one" => 1, "first" => 1,
        "둘" => 2, "두" => 2, "이" => 2, "two" => 2, "second" => 2,
        "셋" => 3, "세" => 3, "삼" => 3, "three" => 3, "third" => 3,
        "넷" => 4, "네" => 4, "사" => 4, "four" => 4, "fourth" => 4,
        "다섯" => 5, "오" => 5, "five" => 5, "fifth" => 5
      }.freeze

      APPROVE  = /(승인|허용|적용|approve|allow|confirm|네|좋아|오케이|ok)/i
      DENY     = /(거절|거부|반려|deny|reject|취소해|아니|no)/i
      STOP     = /(멈춰|중지|정지|그만|stop|cancel|halt)/i
      CONTINUE = /(계속|이어|진행해|continue|resume|proceed)/i
      STATUS   = /(상태|상황|어떻게.?(돼|되|진행)|status|progress)/i

      def initialize(registry:, locale:)
        @registry = registry
        @locale = locale
      end

      def resolve(text)
        det = deterministic(text)
        return det if det

        refs = @registry.active_refs.to_a
        llm = IntentClassifier.new(locale: @locale, refs: refs).classify(text)
        if llm
          Resolution.new(intent: llm.intent || "unknown", ref: llm.ref, behavior: llm.behavior,
                         confidence: llm.confidence, source: "llm")
        else
          Resolution.new(intent: "relay", confidence: 0.0, source: "degraded")
        end
      end

      private

      def deterministic(text)
        t = text.to_s.strip
        ref = extract_ref(t)

        if t.match?(APPROVE)
          Resolution.new(intent: "approve", ref: ref, behavior: "allow", confidence: 1.0, source: "grammar")
        elsif t.match?(DENY)
          Resolution.new(intent: "deny", ref: ref, behavior: "deny", confidence: 1.0, source: "grammar")
        elsif t.match?(STOP)
          Resolution.new(intent: "stop", ref: ref, confidence: 1.0, source: "grammar")
        elsif t.match?(CONTINUE)
          Resolution.new(intent: "continue", ref: ref, confidence: 1.0, source: "grammar")
        elsif t.match?(STATUS)
          Resolution.new(intent: "status", ref: ref, confidence: 1.0, source: "grammar")
        end
      end

      # Integer | :all | :last | nil
      def extract_ref(text)
        return :all  if text.match?(/(전부|모두|전체|다\s|all|everything)/i)
        return :last if text.match?(/(방금|마지막|최근|직전|last|recent|latest)/i)

        if (m = text.match(/(\d+)\s*번?/))
          return m[1].to_i
        end

        NUMBER_WORDS.each { |word, n| return n if text.include?(word) }
        nil
      end
    end
  end
end
