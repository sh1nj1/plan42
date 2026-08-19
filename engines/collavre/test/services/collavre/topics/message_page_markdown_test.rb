# frozen_string_literal: true

require "test_helper"

module Collavre
  module Topics
    class MessagePageMarkdownTest < ActiveSupport::TestCase
      def entry(**overrides)
        {
          topic_id: 12, topic_name: "Planning", creative_id: 7,
          total_count: 130, total_chars: 4200,
          offset: 0, limit: 2, returned_count: 2, returned_chars: 20,
          has_more: true, next_offset: 2, newest_message_id: 991,
          messages: [
            { id: 990, created_at: "2026-08-19T10:00:00Z", author: "One", agent: false, content: "first" },
            { id: 991, created_at: "2026-08-19T10:01:00Z", author: "Bot", agent: true, content: "second" }
          ]
        }.merge(overrides)
      end

      test "renders a header with totals and the window that was returned" do
        output = MessagePageMarkdown.call({ topics: [ entry ], truncated: false })

        assert_includes output, "## [topic 12] Planning (creative 7)"
        assert_includes output, "130 messages, ~4200 raw chars"
        assert_includes output, "showing 0-1 of 130"
      end

      test "spells out the next call including the snapshot anchor" do
        output = MessagePageMarkdown.call({ topics: [ entry ], truncated: false })

        assert_includes output, "topic_messages(topic_ids: 12, offset: 2, max_message_id: 991)"
      end

      test "omits the continuation line when the topic is fully read" do
        output = MessagePageMarkdown.call({ topics: [ entry(has_more: false, next_offset: nil) ], truncated: false })

        assert_not_includes output, "More:"
      end

      test "marks agent authors and renders each message with its id and time" do
        output = MessagePageMarkdown.call({ topics: [ entry ], truncated: false })

        assert_includes output, "[990] 2026-08-19T10:00:00Z One\nfirst"
        assert_includes output, "[991] 2026-08-19T10:01:00Z Bot (agent)\nsecond"
      end

      test "shows 'none' rather than a nonsense range when the window is empty" do
        output = MessagePageMarkdown.call(
          { topics: [ entry(returned_count: 0, messages: [], has_more: false) ], truncated: false }
        )

        assert_includes output, "showing none of 130"
      end

      test "an unfetched topic says so instead of reading as an empty conversation" do
        skipped = { topic_id: 45, topic_name: "Later", creative_id: 7,
                    skipped_reason: "max_chars budget spent on earlier topics", messages: [] }
        output = MessagePageMarkdown.call({ topics: [ skipped ], truncated: true })

        assert_includes output, "## [topic 45] Later (creative 7)"
        assert_includes output, "Not fetched: max_chars budget spent on earlier topics"
        assert_includes output, "Output hit max_chars"
      end

      test "an unreadable topic is reported in place, not dropped" do
        output = MessagePageMarkdown.call(
          { topics: [ entry, { topic_id: 99, error: "Topic not found or not readable" } ], truncated: false }
        )

        assert_includes output, "## [topic 99] unavailable"
        assert_includes output, "Topic not found or not readable"
        assert_includes output, "## [topic 12] Planning"
      end
    end
  end
end
