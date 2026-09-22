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
        data[:read_only] = topic.history?
        data[:display_name] = I18n.t("collavre.topics.history_name") if data[:read_only]
        data[:archived_at] = topic.archived_at if topic.archived_at
        data[:unread_count] = unread_count unless unread_count.nil?
        data
      end

      def with_agent(topic, agent)
        data = topic.slice(:id, :name, :source_topic_id)
        data[:primary_agent] = agent ? agent_json(agent) : nil
        data[:agent_locked] = topic.session_id.present?
        data[:read_only] = topic.history?
        data[:display_name] = I18n.t("collavre.topics.history_name") if data[:read_only]
        data
      end

      # Matches ApplicationHelper#user_json's shape, but resolves the avatar
      # itself. user_json reaches main_app.url_for, which needs the request that
      # only the controller path has — the MCP tools broadcast this same event
      # from outside one, and calling it there raises NameError. An attached
      # avatar therefore resolves to a path, the way CreativesChannel already
      # does for its out-of-request broadcasts; the client is same-origin, so a
      # path merges into the sidebar the same as an absolute URL did.
      AVATAR_SIZE = 20

      def agent_json(agent)
        {
          id: agent.id,
          name: agent.display_name,
          avatar_url: avatar_url_for(agent),
          default_avatar: !agent.avatar.attached? && agent.avatar_url.blank?,
          initial: agent.display_name&.at(0)&.upcase || "?"
        }
      end

      def avatar_url_for(agent)
        if agent.avatar.attached?
          variant = agent.avatar.variant(resize_to_fill: [ AVATAR_SIZE, AVATAR_SIZE ])
          ::Rails.application.routes.url_helpers.rails_representation_path(variant, only_path: true)
        elsif agent.avatar_url.present?
          agent.avatar_url
        else
          ::ApplicationController.helpers.asset_path("default_avatar.svg")
        end
      end

      # The compact shape the MCP tools return. Deliberately not the broadcast
      # payload: an agent wants names and counts it can reason about, not the
      # avatar URLs and merge-semantics keys the sidebar needs.
      def for_tool(topic, message_count: nil, message_chars: nil, last_message_at: nil)
        {
          id: topic.id,
          name: topic.history? ? Creative::HISTORY_TOPIC_NAME : topic.name,
          creative_id: topic.creative_id,
          archived: topic.archived?,
          main: topic.name == Creative::MAIN_TOPIC_NAME,
          read_only: topic.history?,
          system: topic.creative.inbox? && topic.name == Creative::SYSTEM_TOPIC_NAME,
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
