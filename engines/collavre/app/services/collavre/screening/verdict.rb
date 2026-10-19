# frozen_string_literal: true

module Collavre
  module Screening
    # residual: the strictest verdict among screeners that did answer, kept for
    # when the owner approves a turn another screener could not answer for.
    Verdict = Struct.new(:verdict, :screener_id, :model, :probability, :error, :residual, keyword_init: true) do
      def self.from(result, screener)
        probability = Float(result.dig("answers", "injection", "probability"))
        verdict = if probability >= SystemSetting.screening_block_threshold then "blocked"
        elsif probability >= SystemSetting.screening_threshold then "flagged"
        else "passed"
        end
        new(verdict: verdict, screener_id: screener.id, model: screener.model, probability: probability)
      end

      def self.error(screener, exception)
        new(verdict: "error", screener_id: screener.id, model: screener.model, error: exception.class.name)
      end

      def self.strictest(verdicts)
        verdicts.max_by { |v| SEVERITY.fetch(v.verdict) }
      end

      def to_h
        super.except(:residual).compact.transform_keys(&:to_s)
      end
    end
  end
end
