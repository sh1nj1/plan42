# frozen_string_literal: true

module Collavre
require "sorbet-runtime"
require "rails_mcp_engine"
module Tools
  # Moves one complete topic to another creative using the same relocation
  # primitive as the drag-and-drop UI.
  class TopicMoveService
    extend T::Sig
    extend ToolMeta

    tool_name "topic_move"
    tool_description <<~DESC.strip
      Move a complete topic to another creative while keeping its topic id,
      messages, archive state, and read cursors.

      The primary-agent pin moves too when that agent can still respond on the
      destination. Otherwise the pin is released and the result explains why,
      so the moved topic remains routable. Creative permissions do not move:
      people who could read the source may lose access at the destination.

      Requires admin permission on the topic's current creative and write
      permission on the destination. The destination id may be a linked
      creative; the topic moves to its origin. Topic names are unique per
      creative. Main, an inbox's System topic, and live agent session topics
      cannot be moved. Wait for or cancel active agent work before moving its
      topic.
    DESC

    tool_param :topic_id, description: "The topic to move."
    tool_param :creative_id, description: "The destination creative. Linked creatives resolve to their origin."

    sig { params(topic_id: Integer, creative_id: Integer).returns(T::Hash[Symbol, T.untyped]) }
    def call(topic_id:, creative_id:)
      user = Current.user || raise(I18n.t("collavre.tools.topic_move.errors.current_user_required"))
      topic = Topic.find(topic_id)
      authorize_source!(topic, user)
      target = Creative.find(creative_id).effective_origin
      authorize_target!(target, user)
      source = topic.creative.effective_origin

      released_agent, released_reason = move(topic, target, source, user)

      Topics::Serializer.for_tool(topic).merge(
        moved_from_creative_id: source.id,
        released_primary_agent: released_agent_payload(released_agent, released_reason, target)
      ).compact
    end

    private

    def move(topic, target, source, user)
      effects = Topics::TopicMoveEffects.new(topic, source, target)
      Topics::TopicMove.new(topic: topic, target_creative: target).call(after_commit: effects.method(:call)) do |locked_topic|
        authorize_source!(locked_topic, user)
        authorize_target!(target, user)
        validate_move!(locked_topic, target)
      end
    end

    def authorize_source!(topic, user)
      TopicAuthorizer.authorize_admin!(topic, user: user)
    rescue PermissionDeniedError
      raise PermissionDeniedError, I18n.t("collavre.tools.topic_move.errors.source_permission")
    end

    def authorize_target!(target, user)
      TopicAuthorizer.authorize_creative!(target, :write, user: user)
    rescue PermissionDeniedError
      raise PermissionDeniedError, I18n.t("collavre.tools.topic_move.errors.target_permission")
    end

    def validate_move!(topic, target)
      raise ArgumentError, I18n.t("collavre.tools.topic_move.errors.same_creative") if topic.creative_id == target.id
      raise ArgumentError, I18n.t("collavre.tools.topic_move.errors.reserved_topic") if reserved?(topic, target)
      raise ArgumentError, I18n.t("collavre.tools.topic_move.errors.session_topic") if topic.session_id.present?
      return unless target.topics.where(name: topic.name).exists?

      raise ArgumentError, I18n.t("collavre.tools.topic_move.errors.duplicate_name", name: topic.name)
    end

    def reserved?(topic, target)
      Topics::ReservedName.reserved?(topic.creative, topic.name) ||
        Topics::ReservedName.reserved?(target, topic.name)
    end

    def released_agent_payload(agent, reason, target)
      return unless agent

      {
        id: agent.id,
        name: agent.display_name,
        reason: reason.to_s,
        message: released_agent_message(agent, reason, target)
      }
    end

    def released_agent_message(agent, reason, target)
      key = reason == :session_agent_outside_session_topic ?
        "primary_agent_released_session_agent" : "primary_agent_released"
      I18n.t("collavre.topics.move.#{key}", agent: agent.display_name, creative: target.creative_snippet)
    end
  end
end
end
