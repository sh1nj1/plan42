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

      def approval_summary(ref_number:, comment:, label:)
        payload = parse_action(comment)
        detail =
          payload&.dig("description").presence ||
          payload&.dig("tool_name").presence ||
          t("a_tool")
        t("approval", number: ref_number, label: label, detail: flatten(detail))
      end

      def reply_summary(ref_number:, content:, label:)
        t("reply", number: ref_number, label: label, text: truncate(content))
      end

      private

      def t(key, **args)
        I18n.with_locale(@locale) { I18n.t("collavre.mobile.summary.#{key}", **args) }
      end

      def flatten(text)
        text.to_s.gsub(/\s+/, " ").strip
      end

      def truncate(text, limit = 280)
        s = flatten(text)
        s.length > limit ? "#{s[0, limit]}…" : s
      end

      def parse_action(comment)
        return nil if comment.action.blank?

        JSON.parse(comment.action)
      rescue JSON::ParserError
        nil
      end
    end
  end
end
