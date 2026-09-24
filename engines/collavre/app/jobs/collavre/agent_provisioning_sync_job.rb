# frozen_string_literal: true

module Collavre
  # Asks the proxy to re-read every workspace manifest of one agent, so a
  # manifest-carried setting (Codex Fast mode) applies now instead of at the
  # proxy's next hourly refetch.
  #
  # A plain sync, not a registration: a workspace whose manifest never reached
  # the proxy has no login yet, and the login registers it with the current
  # manifest anyway. Such a workspace answers an error, which is logged and
  # does not stop the others.
  class AgentProvisioningSyncJob < ApplicationJob
    queue_as :gateway_health

    def perform(agent_id)
      agent = User.find_by(id: agent_id)
      return unless agent&.cli_proxy_agent? && agent.agent_gateway.active?

      agent.agent_workspaces.where(agent_gateway_id: agent.agent_gateway_id).find_each do |workspace|
        sync(workspace)
      end
    end

    private

    def sync(workspace)
      CliProxy::Client.new(gateway: workspace.agent_gateway, workspace: workspace).provision_sync
    rescue CliProxy::Client::Error => e
      Rails.logger.warn(
        "[AgentProvisioningSyncJob] workspace=#{workspace.id} #{e.code || e.status}: #{e.message}"
      )
    end
  end
end
