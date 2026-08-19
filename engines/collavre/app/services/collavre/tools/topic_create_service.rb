module Collavre
require "sorbet-runtime"
require "rails_mcp_engine"
module Tools
  # Creates a topic on a creative, optionally pinning a primary agent and
  # optionally moving existing messages into it.
  #
  # This is the fan-out primitive. Topics are the concurrency unit — tasks in
  # one topic queue behind each other, tasks in different topics run in parallel
  # — so an agent that can only create creatives can split work up on paper but
  # cannot actually run it in parallel. Creating a topic per unit of work, with
  # the agent that owns it pinned, is what turns a plan into concurrent work.
  class TopicCreateService
    extend T::Sig
    extend ToolMeta

    tool_name "topic_create"
    tool_description <<~DESC.strip
      Create a topic (conversation thread) on a creative.

      Topics are how work runs in parallel in Collavre: tasks dispatched in the
      same topic are serialized — one holds the topic's slot while the rest
      queue — while tasks in different topics run concurrently. Split work into
      one topic per independently-runnable unit; do not pile parallel work into
      one topic expecting it to overlap.

      primary_agent pins one agent to the topic. A pin is EXCLUSIVE: the pinned
      agent alone answers ambient messages there and no other agent responds, so
      use it for a dedicated 1:1 working channel and leave it unset for a thread
      several participants should hear. The agent must already have feedback
      permission or better on the creative, otherwise the pin is refused (a
      pinned agent that cannot answer would silence the topic for everyone).

      Accepts an agent id, email, or exact name for primary_agent. Omit `name`
      to get the next default name ("Topic 3").

      comment_ids moves existing messages out of their current topic into the
      new one. To copy messages and leave the originals in place, use
      topic_branch instead.

      Requires write permission on the creative.
    DESC

    tool_param :creative_id, description: "The creative to create the topic on."
    tool_param :name, description: "Topic name. Must be unique on the creative. Defaults to the next generated name, e.g. \"Topic 3\".", required: false
    tool_param :primary_agent, description: "Agent to pin to this topic — id, email, or exact name. The pin is exclusive: only this agent answers here. The agent needs feedback permission or better on the creative.", required: false
    tool_param :comment_ids, description: "Comma-separated ids of existing messages to MOVE into the new topic. Use topic_branch to copy instead of move.", required: false

    sig do
      params(
        creative_id: Integer,
        name: T.nilable(String),
        primary_agent: T.nilable(String),
        comment_ids: T.nilable(T.any(String, Integer, T::Array[T.untyped]))
      ).returns(T::Hash[Symbol, T.untyped])
    end
    def call(creative_id:, name: nil, primary_agent: nil, comment_ids: nil)
      user = Current.user || raise("Current.user is required")
      creative = Creative.find(creative_id).effective_origin
      TopicAuthorizer.authorize_creative!(creative, :write, user: user)

      agent = resolve_agent(primary_agent, creative)
      topic = build_topic(creative, name, user)

      Topic.transaction do
        topic.save!
        topic.set_primary_agent!(agent) if agent
        move_comments(creative, user, topic, comment_ids)
      end

      broadcast(creative, topic, agent, user)
      Topics::Serializer.for_tool(topic)
    end

    private

    # Checked before the topic exists, exactly as TopicsController#create does:
    # a topic created here never carries a session_id, so a Claude Channel
    # session agent can never be routed on it and pinning one would produce a
    # dead topic rather than an error.
    def resolve_agent(primary_agent, creative)
      resolved = Topics::AgentResolver.call(primary_agent)
      return nil if resolved.nil? || resolved == Topics::AgentResolver::CLEAR

      rejection = Topic.primary_agent_rejection(creative, resolved)
      raise ArgumentError, Topics::PinRejection.message(resolved, rejection) if rejection

      resolved
    end

    def build_topic(creative, name, user)
      creative.topics.build(name: name.presence || Topics::NextName.for(creative), user: user)
    end

    def move_comments(creative, user, topic, comment_ids)
      ids = IdList.parse(comment_ids)
      return if ids.empty?

      CommentMoveService.new(creative: creative, user: user).call(comment_ids: ids, target_topic_id: topic.id)
    end

    # user_id in the payload is what makes the creating user's own client select
    # the new topic. Included for parity with TopicsController#create: a user
    # asking an agent to open a topic expects to land in it, the same as if they
    # had made it themselves.
    def broadcast(creative, topic, agent, user)
      payload = agent ? Topics::Serializer.with_agent(topic, agent) : topic.slice(:id, :name)
      TopicsChannel.broadcast_to(creative, { action: "created", topic: payload, user_id: user.id })
    end
  end
end
end
