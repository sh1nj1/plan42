# frozen_string_literal: true

module Collavre
  module AiAgent
    # Prompt preamble for a document-mode quote (Comment#creative_quote?): tells
    # the agent which creative the user selected from, how far an edit may
    # reach, where the selection sits, and whether it may write at all.
    #
    # The selection is located by text rather than by offsets: offsets do not
    # survive the Lexical/HTML/markdown round trips a description goes through,
    # while a short window of surrounding text is enough to disambiguate.
    class CreativeQuoteContext
      CONTEXT_CHARS = 120
      MAX_SCAN = 200

      def self.prepend_to(text, comment)
        return text unless comment&.creative_quote? && comment.quoted_creative

        "#{new(comment).text}\n\n#{text}"
      end

      def initialize(comment)
        @comment = comment
        @creative = comment.quoted_creative
      end

      def text
        key = @comment.review_type_question? ? "question" : "review"
        parts = [ I18n.t("collavre.ai_agent.creative_quote.#{key}", id: @creative.id, title: title) ]
        location = locate
        parts << I18n.t("collavre.ai_agent.creative_quote.location", id: location[:id], excerpt: location[:excerpt]) if location
        parts.join("\n")
      end

      private

      def title
        Collavre::HtmlText.truncated_label(@creative.effective_origin.description, 60)
      end

      def locate
        needle = @comment.quoted_text.to_s.squish
        return if needle.blank?

        candidates.each do |creative|
          haystack = Collavre::HtmlText.label(creative.effective_origin.description)
          index = haystack.index(needle)
          next unless index

          return { id: creative.id, excerpt: excerpt(haystack, index, needle.length) }
        end
        nil
      end

      def candidates
        [ @creative ] + @creative.descendants.limit(MAX_SCAN).to_a
      end

      def excerpt(haystack, index, length)
        before = haystack[[ index - CONTEXT_CHARS, 0 ].max...index]
        after = haystack[(index + length), CONTEXT_CHARS]
        "…#{before}«#{haystack[index, length]}»#{after}…"
      end
    end
  end
end
