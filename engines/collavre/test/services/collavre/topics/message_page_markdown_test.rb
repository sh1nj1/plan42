# frozen_string_literal: true

require "test_helper"

module Collavre
  module Topics
    class MessagePageMarkdownTest < ActiveSupport::TestCase
      def entry(**overrides)
        {
          topic_id: 12, topic_name: "Planning", creative_id: 7,
          total_count: 130, total_chars: 4200,
          offset: 0, limit: 2, max_chars: 1_000, returned_count: 2, returned_chars: 20,
          has_more: true, next_offset: 2,
          next_cursor: "1770000000000000:989:1770000001000000:1770000002000000", newest_message_id: 991,
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

        assert_includes output,
                        "topic_messages(topic_ids: 12, offset: 2, " \
                          "cursor: \"1770000000000000:989:1770000001000000:1770000002000000\", " \
                          "max_message_id: 991, limit: 2, max_chars: 1000)"
      end

      test "spells out the content continuation without consuming the clipped row" do
        output = MessagePageMarkdown.call(
          { topics: [ entry(next_offset: 0, next_content_offset: 320) ], truncated: true }
        )

        assert_includes output,
                        "offset: 0, cursor: \"1770000000000000:989:1770000001000000:1770000002000000\", " \
                          "max_message_id: 991, " \
                          "limit: 2, max_chars: 1000, content_offset: 320"
      end

      test "repeats newest-first rendering order in the continuation" do
        output = MessagePageMarkdown.call(
          { topics: [ entry(order: "desc") ], truncated: false }
        )

        assert_includes output, 'max_chars: 1000, order: "desc")'
      end

      test "leaves the default rendering order out of the continuation" do
        output = MessagePageMarkdown.call(
          { topics: [ entry(order: "asc") ], truncated: false }
        )

        assert_not_includes output, "order:"
      end

      # Dropping include_system from the follow-up call pages a narrower set at
      # an offset counted against the wider one, which walks straight past
      # messages the caller has not seen.
      test "repeats include_system in the next call so the follow-up pages the same set" do
        output = MessagePageMarkdown.call({ topics: [ entry(include_system: true) ], truncated: false })

        assert_includes output, "max_chars: 1000, include_system: true)"
      end

      test "leaves include_system out of the next call when it was not requested" do
        output = MessagePageMarkdown.call({ topics: [ entry ], truncated: false })

        assert_not_includes output, "include_system"
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

      test "renders a clipped message notice outside its retrievable content fragment" do
        clipped = entry(messages: [ entry[:messages].first.merge(content: "fragment", clip_notice: "continue") ])
        output = MessagePageMarkdown.call({ topics: [ clipped ], truncated: true })

        assert_includes output, "\nfragment\ncontinue\n"
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
        assert_empty output.lines.grep(/\AMore:/)
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
