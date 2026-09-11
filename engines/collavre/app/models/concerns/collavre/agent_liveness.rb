# frozen_string_literal: true

module Collavre
  # Whether an agent can be dispatched to right now.
  #
  # Deliberately independent of chat presence: presence answers "who has this
  # creative open", which drives read receipts and unread badges, while this
  # answers "can this agent run", which is true whether or not anyone is
  # watching. The two meet only where an avatar paints its online dot.
  module AgentLiveness
    extend ActiveSupport::Concern

    ENDPOINT_HEALTH_TTL = 3.minutes
    ENDPOINT_HEALTH_CONFIGURATION_ATTRIBUTES = %w[llm_vendor llm_api_key gateway_url].freeze

    included do
      # SQL TRIM/LOWER differ from Ruby for control whitespace and Unicode.
      # Normalize distinct stored spellings, then filter rows by their exact values.
      scope :with_llm_vendors, ->(vendors) do
        spellings = distinct.pluck(:llm_vendor).select { |value| vendors.include?(value.to_s.strip.downcase) }
        where(llm_vendor: spellings)
      end

      enum :endpoint_health_status,
           { unknown: 0, online: 1, offline: 2, check_error: 3 },
           prefix: :endpoint_health,
           default: :unknown

      after_update :invalidate_endpoint_health_after_configuration_change,
                   if: :endpoint_health_configuration_changed?
    end

    def claude_channel_agent?
      llm_model == "claude-code"
    end

    def claude_channel_online?(live_agent_ids: nil)
      return false unless claude_channel_agent?
      return live_agent_ids.include?(id) if live_agent_ids

      AgentSubscription.live.where(agent_id: id).exists?
    end

    # A gateway-backed agent is reachable when its gateway's last readiness
    # probe is recent, positive, and does not name this agent's own engine as
    # logged out. See docs/agent_gateway_health.md.
    def gateway_online?
      return false unless cli_proxy_agent?

      agent_gateway.health_serves_engine?(CliProxy::AdapterEngine.for_model(llm_model))
    end

    def endpoint_health_supported?
      AgentHealth.checker_for(llm_vendor).present?
    end

    def endpoint_health_fresh?
      endpoint_health_checked_at.present? && endpoint_health_checked_at > ENDPOINT_HEALTH_TTL.ago
    end

    def endpoint_online?
      endpoint_health_supported? && endpoint_health_fresh? && endpoint_health_online?
    end

    def agent_liveness_status(live_claude_agent_ids: nil)
      return :online if claude_channel_online?(live_agent_ids: live_claude_agent_ids)
      return :online if gateway_online? || endpoint_online?
      return :offline if claude_channel_agent? || cli_proxy_agent?
      return :unknown unless ai_user? && endpoint_health_supported? && endpoint_health_fresh?

      endpoint_health_status.to_sym
    end

    # Only presence sources and registered health checkers publish evidence.
    # Other vendors stay unknown rather than being asserted online on nothing.
    def agent_online?(live_claude_agent_ids: nil)
      agent_liveness_status(live_claude_agent_ids:) == :online
    end

    private

    def endpoint_health_configuration_changed?
      (saved_changes.keys & ENDPOINT_HEALTH_CONFIGURATION_ATTRIBUTES).any?
    end

    def invalidate_endpoint_health_after_configuration_change
      update_columns(
        endpoint_health_status: self.class.endpoint_health_statuses.fetch("unknown"),
        endpoint_health_error: nil,
        endpoint_health_checked_at: nil
      )
    end
  end
end
