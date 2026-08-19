# frozen_string_literal: true

module Collavre
  module Topics
    # Renders the topic_messages payload as markdown.
    #
    # Renders the *payload*, not the records, so the markdown and json formats
    # of the same call cannot disagree about what was returned — the json branch
    # returns the identical hash this reads.
    #
    # Markdown is the default format because the content is prose. Wrapping
    # conversation in JSON escaping costs a large fraction of the character
    # budget the paging exists to protect, and buys nothing: the caller is going
    # to read the words, not index into them.
    module MessagePageMarkdown
      module_function

      def call(payload)
        sections = payload[:topics].map { |topic| render_topic(topic) }
        sections << truncation_notice if payload[:truncated]
        sections.join("\n")
      end

      def render_topic(entry)
        return render_error(entry) if entry[:error]
        return "#{title(entry)}\n#{skipped_notice(entry)}\n" if entry[:skipped_reason]

        [ header(entry), *continuation(entry), "", *body(entry) ].join("\n")
      end

      def render_error(entry)
        "## [topic #{entry[:topic_id]}] unavailable\n#{entry[:error]}\n"
      end

      def title(entry)
        "## [topic #{entry[:topic_id]}] #{entry[:topic_name]} (creative #{entry[:creative_id]})"
      end

      def header(entry)
        "#{title(entry)}\n" \
          "#{entry[:total_count]} messages, ~#{entry[:total_chars]} raw chars — " \
          "showing #{shown_range(entry)} of #{entry[:total_count]}, newest-first window"
      end

      def shown_range(entry)
        return "none" if entry[:returned_count].to_i.zero?

        "#{entry[:offset]}-#{entry[:offset] + entry[:returned_count] - 1}"
      end

      # The next call is spelled out rather than left as a next_offset field to
      # decode. max_message_id is repeated into it because that is the whole
      # point of the anchor — a caller that drops it silently re-reads messages
      # as the topic grows underneath the pagination.
      #
      # include_system is repeated for the same reason, and it matters more:
      # the anchor shifts rows, but a narrower scope renumbers them. Paging
      # into a set that no longer contains the system rows the first page
      # counted lands the offset past messages that were never returned.
      def continuation(entry)
        return [] unless entry[:has_more]

        [ "More: topic_messages(topic_ids: #{entry[:topic_id]}, offset: #{entry[:next_offset]}, " \
          "max_message_id: #{entry[:newest_message_id]}#{scope_option(entry)})" ]
      end

      def scope_option(entry)
        entry[:include_system] ? ", include_system: true" : ""
      end

      def skipped_notice(entry)
        "Not fetched: #{entry[:skipped_reason]}. Re-request this topic alone, or raise max_chars."
      end

      # Oldest-to-newest within the window by default, so the transcript reads
      # forwards even though the window was chosen from the newest end.
      def body(entry)
        entry[:messages].map do |message|
          "[#{message[:id]}] #{message[:created_at]} #{message[:author]}" \
            "#{message[:agent] ? ' (agent)' : ''}\n#{message[:content]}\n"
        end
      end

      def truncation_notice
        "> Output hit max_chars. Topics above may be partial — see each topic's " \
          "\"More:\" line, or request fewer topics per call.\n"
      end
    end
  end
end
