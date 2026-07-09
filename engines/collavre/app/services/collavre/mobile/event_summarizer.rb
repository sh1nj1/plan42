# frozen_string_literal: true

module Collavre
  module Mobile
    # Turns an approval/permission comment or an agent reply into a SHORT,
    # decision-oriented line of speech. Deterministic (no LLM) so the hot path
    # stays fast: it extracts the tool name / human description from the
    # permission action payload and renders a localized, spoken-friendly summary.
    class EventSummarizer
      def initialize(locale:)
        @locale = (locale.presence || I18n.default_locale).to_s
      end

      def approval_summary(comment:, label:)
        payload = parse_action(comment)
        I18n.with_locale(@locale) do
          detail =
            payload&.dig("description").presence ||
            payload&.dig("tool_name").presence ||
            I18n.t("collavre.mobile.summary.a_tool")
          I18n.t("collavre.mobile.summary.approval", label: label, detail: flatten(detail))
        end
      end

      private

      def flatten(text)
        text.to_s.gsub(/\s+/, " ").strip
      end

      def parse_action(comment)
        return nil unless comment.approval_action?

        JSON.parse(comment.action)
      rescue JSON::ParserError
        nil
      end
    end
  end
end
