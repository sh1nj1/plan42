# frozen_string_literal: true

module Collavre
  module Topics
    # The topic payload the client merges into its cached sidebar entry, built
    # outside a controller so TopicsController and the topic MCP tools cannot
    # describe the same topic two different ways.
    #
    # The client merges rather than replaces, so a key that is sometimes omitted
    # leaves stale state on screen. That is why #with_agent always carries
    # :primary_agent, explicitly nil when the pin was cleared.
    module Serializer
      module_function

      def call(topic, unread_count: nil)
        data = topic.slice(:id, :name, :source_topic_id)
        data[:primary_agent] = agent_json(topic.primary_agent) if topic.primary_agent
        data[:agent_locked] = topic.session_id.present?
        data[:archived_at] = topic.archived_at if topic.archived_at
        data[:unread_count] = unread_count unless unread_count.nil?
        data
      end

      def with_agent(topic, agent)
        data = topic.slice(:id, :name, :source_topic_id)
        data[:primary_agent] = agent ? agent_json(agent) : nil
        data[:agent_locked] = topic.session_id.present?
        data
      end

      # Avatar URLs are built by a view helper, so reach it through the
      # controller's helper proxy rather than duplicating the variant/asset
      # fallback logic here.
      def agent_json(agent)
        ::ApplicationController.helpers.user_json(agent)
      end

      # The compact shape the MCP tools return. Deliberately not the broadcast
      # payload: an agent wants names and counts it can reason about, not the
      # avatar URLs and merge-semantics keys the sidebar needs.
      def for_tool(topic, message_count: nil, message_chars: nil, last_message_at: nil)
        {
          id: topic.id,
          name: topic.name,
          creative_id: topic.creative_id,
          archived: topic.archived?,
          main: topic.name == Creative::MAIN_TOPIC_NAME,
          system: topic.name == Creative::SYSTEM_TOPIC_NAME,
          source_topic_id: topic.source_topic_id,
          primary_agent: primary_agent_for_tool(topic),
          # A session topic's pin is session identity, not a routing choice, and
          # topic_update refuses to rewrite it. Say so here so an agent does not
          # plan a reassignment that is going to be rejected.
          agent_locked: topic.session_id.present?,
          message_count: message_count,
          message_chars: message_chars,
          last_message_at: last_message_at&.iso8601
        }.compact
      end

      def primary_agent_for_tool(topic)
        agent = topic.primary_agent
        return nil unless agent

        { id: agent.id, name: agent.display_name }
      end
    end
  end
end
