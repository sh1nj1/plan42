module Collavre
require "sorbet-runtime"
require "rails_mcp_engine"
module Tools
  # Lists a creative's topics, or describes specific topics by id.
  #
  # This is the planning call. A topic is a Collavre conversation's concurrency
  # unit — work in separate topics runs in parallel, work piled into one topic
  # queues — so an agent deciding how to split a job needs to see what topics
  # already exist, who is pinned to them, and how much conversation each one
  # holds, before it reads a single message.
  class TopicListService
    extend T::Sig
    extend ToolMeta

    tool_name "topic_list"
    tool_description <<~DESC.strip
      List the topics of a creative, or describe specific topics by id.

      A topic is a conversation thread on a creative, and it is also the unit of
      agent concurrency: tasks in different topics run in parallel, tasks in the
      same topic queue behind each other. Use this before splitting work up, and
      before calling topic_messages — the per-topic message_count and
      message_chars tell you how much conversation you would be pulling in, so
      you can pick an offset/limit that fits your context.

      Pass creative_id to list a creative's topics, or topic_ids to describe
      known topics (which may live on different creatives). Returns, per topic:
      id, name, creative_id, archived, main/system flags, source_topic_id (set
      when the topic was branched off another), primary_agent, agent_locked, and
      the message totals.

      message_chars combines stored message HTML length with a conservative
      estimate for image attachment markers. It is useful for relative sizing,
      not exact budgeting.

      Requires read permission on each topic's creative. Unknown or unreadable
      ids come back in "errors" instead of failing the call.
    DESC

    tool_param :creative_id, description: "List every topic on this creative. Either this or topic_ids is required.", required: false
    tool_param :topic_ids, description: "Describe these specific topics. Comma-separated ids, e.g. \"12,45,78\" (max #{TopicSelection::MAX_TOPICS} per call — asking for more is an error, not a silent trim). Either this or creative_id is required.", required: false
    tool_param :include_archived, description: "Include archived topics when listing by creative_id (default: false). Archived topics keep their messages and stay readable by id.", required: false
    tool_param :include_stats, description: "Include message_count / message_chars / last_message_at (default: true). Pass false to skip the totals query on a creative with very many topics.", required: false
    tool_param :include_system, description: "Count authorless system messages in the totals (default: false). Approval prompts are never counted. Matches the topic_messages default so the counts describe the same set of messages you would read back.", required: false

    sig do
      params(
        creative_id: T.nilable(Integer),
        topic_ids: T.nilable(T.any(String, Integer, T::Array[T.untyped])),
        include_archived: T.nilable(T::Boolean),
        include_stats: T.nilable(T::Boolean),
        include_system: T.nilable(T::Boolean)
      ).returns(T::Hash[Symbol, T.untyped])
    end
    def call(creative_id: nil, topic_ids: nil, include_archived: false, include_stats: true, include_system: false)
      user = require_user!
      include_stats = true if include_stats.nil?

      topics, errors = select_topics(creative_id, topic_ids, user, include_archived)
      stats = include_stats ? Topics::MessageStats.for(topics, user: user, include_system: include_system) : {}

      { topics: topics.map { |topic| describe(topic, stats[topic.id]) }, errors: errors }
    end

    private

    def require_user!
      Current.user || raise("Current.user is required")
    end

    def select_topics(creative_id, topic_ids, user, include_archived)
      ids = IdList.parse(topic_ids)
      return TopicSelection.resolve(ids, user: user) if ids.any?
      raise ArgumentError, "Either creative_id or topic_ids is required" if creative_id.blank?

      [ topics_of(creative_id, user, include_archived), [] ]
    end

    # effective_origin because topics hang off the origin creative, not off a
    # link to it — passing a linked creative's id would otherwise list nothing.
    def topics_of(creative_id, user, include_archived)
      creative = Creative.find(creative_id).effective_origin
      TopicAuthorizer.authorize_creative!(creative, :read, user: user)

      scope = creative.topics
      scope = scope.active unless include_archived
      scope.includes(:primary_agent).to_a
    end

    def describe(topic, stat)
      Topics::Serializer.for_tool(
        topic,
        message_count: stat&.count,
        message_chars: stat&.chars,
        last_message_at: stat&.last_at
      )
    end
  end
end
end
