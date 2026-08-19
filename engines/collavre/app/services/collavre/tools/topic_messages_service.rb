module Collavre
require "sorbet-runtime"
require "rails_mcp_engine"
module Tools
  # Reads a page of messages from one or more topics.
  #
  # Multi-topic in one call, but never interleaved: each topic is windowed and
  # reported on its own. A merged cross-topic timeline would be the wrong answer
  # to the question people actually ask ("summarize #a, #b and #c") — three
  # conversations shuffled by timestamp read as none of them — and it would make
  # offset meaningless, since a merged offset moves when any of the topics grows.
  #
  # Per-topic windows keep offset reproducible, and max_chars keeps the total
  # bounded so asking for three topics cannot return three times the context you
  # planned for.
  class TopicMessagesService
    extend T::Sig
    extend ToolMeta

    # Roughly a mid-sized page of prose per call. The cap is on the whole
    # response rather than per topic because the caller's context is the shared
    # resource: five topics at a comfortable per-topic size is not a comfortable
    # call.
    DEFAULT_MAX_CHARS = 40_000
    MAX_MAX_CHARS = 200_000

    # Each topic also pays for its own heading, totals line and "More:" call —
    # or, if it does not fit, its not-fetched notice, which is about the same
    # size. Charged separately from the messages so that a call for many topics
    # cannot overrun the cap on section furniture alone.
    TOPIC_HEADER_CHARS = 200

    # The trailing "output hit max_chars" notice, which only exists when the
    # budget ran out and so cannot be paid for out of what is left of it.
    TRUNCATION_CHARS = 120

    tool_name "topic_messages"
    tool_description <<~DESC.strip
      Read messages from one or more Collavre topics, newest first, with paging.

      Messages are selected from the newest end: offset 0 is the latest message,
      offset 100 starts 100 messages back. Within the returned window they are
      rendered oldest-to-newest by default so the transcript reads forwards
      (pass order: "desc" for newest-first rendering).

      Multiple topics per call are windowed independently and returned grouped
      by topic — offset/limit apply to EACH topic, never to a merged timeline.
      Use this to summarize several topics at once, e.g.
      topic_messages(topic_ids: "12,45,78", limit: 100).

      Every topic reports total_count and total_chars for the whole topic, so
      you can tell how much you have not read yet, plus has_more and next_offset
      for the next call. Pass the returned newest_message_id back as
      max_message_id on follow-up pages: it pins paging to a snapshot, so
      messages arriving mid-read cannot shift rows between pages.

      The response is capped at max_chars in total. A topic that does not fit is
      returned partially or marked not-fetched rather than silently trimmed —
      check "truncated" and each topic's next_offset.

      Long topics: call topic_list first to see message_count, then page. To
      summarize a whole large topic, page from offset 0 upward, keeping
      max_message_id fixed, until has_more is false.

      Requires read permission on each topic's creative. Private messages you
      cannot see and approval prompts are always excluded; authorless system
      notices are excluded by default (see include_system). Unknown or
      unreadable ids are reported per topic instead of failing the call.
    DESC

    tool_param :topic_ids, description: "Topic ids to read. Comma-separated for several, e.g. \"12,45,78\" (max #{TopicSelection::MAX_TOPICS} per call). A single id also works."
    tool_param :offset, description: "How many messages back from the newest to start, applied per topic (default: 0).", required: false
    tool_param :limit, description: "Messages per topic (default: #{Topics::MessagePage::DEFAULT_LIMIT}, max #{Topics::MessagePage::MAX_LIMIT}).", required: false
    tool_param :order, description: "Rendering order within the returned window: 'asc' (default, oldest-to-newest — reads as a transcript) or 'desc' (newest first). Does not change which messages the window selects.", required: false, enum: Topics::MessagePage::ORDERS
    tool_param :max_message_id, description: "Only consider messages with id <= this. Pass the newest_message_id from your first page on every follow-up page so paging stays on one snapshot of a live topic.", required: false
    tool_param :include_system, description: "Include authorless system notices such as concurrency and channel announcements (default: false). Approval prompts are never returned.", required: false
    tool_param :max_chars, description: "Character cap for the whole response across all topics (default: #{DEFAULT_MAX_CHARS}, max #{MAX_MAX_CHARS}).", required: false
    tool_param :format, description: "'markdown' (default, compact transcript) or 'json' (same data, structured).", required: false, enum: %w[markdown json]

    sig do
      params(
        topic_ids: T.any(String, Integer, T::Array[T.untyped]),
        offset: T.nilable(Integer),
        limit: T.nilable(Integer),
        order: T.nilable(String),
        max_message_id: T.nilable(Integer),
        include_system: T.nilable(T::Boolean),
        max_chars: T.nilable(Integer),
        format: T.nilable(String)
      ).returns(T.any(String, T::Hash[Symbol, T.untyped]))
    end
    def call(topic_ids:, offset: 0, limit: nil, order: nil, max_message_id: nil,
             include_system: false, max_chars: nil, format: "markdown")
      user = Current.user || raise("Current.user is required")
      ids = IdList.parse(topic_ids)
      raise ArgumentError, "topic_ids is required" if ids.empty?

      payload = build_payload(
        ids: ids, user: user,
        options: { offset: offset.to_i, limit: limit, order: order, max_message_id: max_message_id,
                   include_system: include_system, budget: clamp_chars(max_chars) }
      )

      format.to_s == "json" ? payload : Topics::MessagePageMarkdown.call(payload)
    end

    private

    def build_payload(ids:, user:, options:)
      topics, errors = TopicSelection.resolve(ids.first(TopicSelection::MAX_TOPICS), user: user)
      entries = collect(topics, user, options)

      {
        topics: entries + errors,
        truncated: entries.any? { |entry| entry[:skipped_reason] || entry[:budget_limited] },
        max_chars: options[:budget]
      }
    end

    # Topics are served in request order and the budget is spent as it goes, so
    # an early huge topic can leave later ones unfetched. That is reported per
    # topic rather than smoothed over: the caller asked for a specific order and
    # needs to know which of its topics it is still missing.
    #
    # What is charged is what is emitted — message envelopes as well as prose.
    # Counting content alone let a few hundred one-word messages print their
    # ids, timestamps and authors for free and sail past the cap.
    #
    # Every requested topic prints a section whether or not it fits, so all the
    # headers are reserved before any topic spends on messages. Reserving them
    # one at a time would charge only the topics that succeed, and the
    # not-fetched notices — which exist precisely because the budget ran out —
    # would push the response over the cap that skipping them was enforcing.
    def collect(topics, user, options)
      remaining = options[:budget] - reserved_chars(topics)
      served = false

      topics.map do |topic|
        next not_fetched(topic, options[:offset], served) if remaining <= 0

        entry = page_entry(topic, user, options, remaining)
        remaining -= entry[:billed_chars].to_i
        served = true
        entry
      end
    end

    def reserved_chars(topics)
      TRUNCATION_CHARS + topics.sum { |topic| TOPIC_HEADER_CHARS + topic.name.to_s.length }
    end

    def page_entry(topic, user, options, remaining)
      page = Topics::MessagePage.new(
        topic: topic, user: user,
        offset: options[:offset], limit: options[:limit], order: options[:order] || Topics::MessagePage::DEFAULT_ORDER,
        include_system: options[:include_system], max_message_id: options[:max_message_id],
        char_budget: remaining
      ).call

      serialize(page, include_system: options[:include_system])
    end

    def serialize(page, include_system:)
      {
        topic_id: page.topic.id,
        topic_name: page.topic.name,
        creative_id: page.topic.creative_id,
        total_count: page.total_count,
        total_chars: page.total_chars,
        offset: page.offset,
        limit: page.limit,
        returned_count: page.returned_count,
        returned_chars: page.returned_chars,
        # What this topic charged against max_chars: prose plus the rendered
        # envelope around each message.
        billed_chars: page.billed_chars,
        has_more: page.has_more?,
        next_offset: page.next_offset,
        newest_message_id: page.newest_message_id,
        # Echoed so the rendered "More:" line can repeat it. A continuation
        # that drops it pages a narrower set at the same offset and skips
        # whatever the wider first page had already counted.
        include_system: (true if include_system),
        # Only present when the shared max_chars budget, rather than `limit`,
        # is what ended this topic's window — the caller's fix differs: raise
        # max_chars or ask for fewer topics, not just page again.
        budget_limited: page.budget_exhausted.presence,
        messages: page.messages
      }.compact
    end

    # Carries has_more/next_offset so the caller can resume this topic without
    # having to work out that "no messages" here means "not read yet" rather
    # than "empty topic".
    #
    # The reason distinguishes the two ways to run out of room, because the
    # fixes differ: drop topics from the call, or raise the cap. Blaming
    # "earlier topics" when this was the first one sends the caller the wrong way.
    def not_fetched(topic, offset, served)
      reason = if served
        "max_chars budget spent on earlier topics"
      else
        "max_chars is too small to return anything for this topic"
      end

      {
        topic_id: topic.id,
        topic_name: topic.name,
        creative_id: topic.creative_id,
        offset: offset,
        returned_count: 0,
        returned_chars: 0,
        billed_chars: 0,
        has_more: true,
        next_offset: offset,
        skipped_reason: reason,
        messages: []
      }
    end

    def clamp_chars(max_chars)
      value = max_chars.to_i
      return DEFAULT_MAX_CHARS if value <= 0

      [ value, MAX_MAX_CHARS ].min
    end
  end
end
end
