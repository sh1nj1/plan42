module Collavre
require "sorbet-runtime"
require "rails_mcp_engine"
module Tools
  # Renames a topic, archives/unarchives it, or changes its primary agent.
  #
  # One tool rather than three because these are the three ways a topic changes
  # after it exists, and they are routinely done together — an agent finishing a
  # unit of work archives the topic and releases the pin in the same breath.
  # They do not share a permission level, so each field is authorized for what
  # it actually does.
  class TopicUpdateService
    extend T::Sig
    extend ToolMeta

    tool_name "topic_update"
    tool_description <<~DESC.strip
      Rename a topic, archive or unarchive it, or set/clear its primary agent.
      Pass only the fields you want to change.

      Archiving is how a finished thread is put away: the topic leaves the
      active sidebar but keeps every message, and topic_messages can still read
      it by id. Archive a topic when its conversation has reached its
      conclusion, rather than reusing it for the next subject — a topic is one
      thread of one conclusion, and it is also the concurrency unit, so reusing
      one serializes unrelated work behind it.

      primary_agent pins one agent to the topic, EXCLUSIVELY: the pinned agent
      alone answers ambient messages and no other agent responds. The agent must
      already have feedback permission or better on the creative. Pass "none" to
      clear the pin and let normal routing resume. Accepts an agent id, email,
      or exact name; private agents already shared on this creative resolve too.

      Permissions: renaming needs admin on the creative (a rename changes what
      everyone else's links and habits point at); archiving and pin changes need
      write. A Claude Channel session topic's pin is part of its session
      identity and cannot be changed here.
    DESC

    tool_param :topic_id, description: "The topic to update."
    tool_param :name, description: "New name. Must be unique on the creative. Requires admin permission.", required: false
    tool_param :archived, description: "true archives the topic (hides it from the active list, keeps all messages); false unarchives it.", required: false
    tool_param :primary_agent, description: "Agent to pin — id, email, or exact name. Pass \"none\" to clear the pin. The pin is exclusive: only this agent answers in the topic.", required: false

    sig do
      params(
        topic_id: Integer,
        name: T.nilable(String),
        archived: T.nilable(T::Boolean),
        primary_agent: T.nilable(String)
      ).returns(T::Hash[Symbol, T.untyped])
    end
    def call(topic_id:, name: nil, archived: nil, primary_agent: nil)
      Current.user || raise("Current.user is required")
      topic = Topic.find(topic_id)

      # Authorize before resolving the agent: resolution reports whether a name
      # matches an accessible agent, and a caller with no rights on the topic
      # should not be able to ask.
      authorize!(topic, name)
      agent_change = Topics::AgentResolver.call(primary_agent, creative: topic.creative)
      changed = requested(name, archived, agent_change)
      raise ArgumentError, "Nothing to update: pass name, archived, or primary_agent" if changed.empty?

      agent = apply(topic, name, archived, agent_change)
      broadcast_all(topic.reload, changed, archived, agent)

      Topics::Serializer.for_tool(topic).merge(changed: changed)
    end

    private

    # A rename is gated at :admin to match TopicsController#update. Everything
    # else here is a :write action, so the stricter gate is only applied when a
    # rename is actually requested — otherwise archiving would silently need
    # admin through this door and not through the UI.
    def authorize!(topic, name)
      name.present? ? TopicAuthorizer.authorize_admin!(topic) : TopicAuthorizer.authorize_write!(topic)
    end

    def requested(name, archived, agent_change)
      changed = []
      changed << "name" if name.present?
      changed << "archived" unless archived.nil?
      changed << "primary_agent" if agent_change
      changed
    end

    # Every requested field is checked before any of them is written, and the
    # writes share one transaction. A call that renames, archives, and pins an
    # agent the creative has not shared with must report failure over a topic
    # that is still named what it was — not one that was quietly renamed and
    # archived on the way to the error. Nothing broadcasts until the whole set
    # has committed, for the same reason.
    def apply(topic, name, archived, agent_change)
      agent = agent_change ? validated_agent(topic, agent_change) : nil

      Topic.transaction do
        topic.update!(name: name) if name.present?
        set_archived(topic, archived) unless archived.nil?
        topic.set_primary_agent!(agent) if agent_change
      end

      agent
    end

    def set_archived(topic, archived)
      archived ? topic.archive! : topic.unarchive!
    end

    # Mirrors TopicsController#set_primary_agent, including the session lock:
    # on a Claude Channel session topic primary_agent_id is session identity,
    # not a routing preference — Matcher needs it to route the agent at all and
    # SessionProvisioner reuses the topic by it, so rewriting it would leave a
    # live session unroutable and fork the next registration into a second topic.
    def validated_agent(topic, agent_change)
      raise ArgumentError, "This is a session topic; its agent assignment is locked." if topic.session_id.present?

      agent = agent_change == Topics::AgentResolver::CLEAR ? nil : agent_change
      reject_unassignable!(topic, agent)
      agent
    end

    def broadcast_all(topic, changed, archived, agent)
      broadcast(topic, "updated", topic: Topics::Serializer.call(topic)) if changed.include?("name")
      broadcast(topic, archived ? "archived" : "unarchived", topic: topic.slice(:id, :name, :archived_at)) if changed.include?("archived")
      broadcast(topic, "updated", topic: Topics::Serializer.with_agent(topic, agent)) if changed.include?("primary_agent")
    end

    def reject_unassignable!(topic, agent)
      return if agent.nil?

      rejection = Topic.primary_agent_rejection(topic.creative, agent, topic: topic)
      return unless rejection

      raise ArgumentError, Topics::PinRejection.message(agent, rejection)
    end

    def broadcast(topic, action, payload)
      TopicsChannel.broadcast_to(topic.creative, { action: action, **payload })
    end
  end
end
end
