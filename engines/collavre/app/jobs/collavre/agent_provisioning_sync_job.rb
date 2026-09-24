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

    def perform(agent_id, workspace_id: nil, attempt: 0)
      agent = User.find_by(id: agent_id)
      return unless agent&.cli_proxy_agent? && agent.agent_gateway.active?

      workspaces = agent.agent_workspaces.where(agent_gateway_id: agent.agent_gateway_id)
      workspaces = workspaces.where(id: workspace_id) if workspace_id
      workspaces.find_each do |workspace|
        sync(workspace, attempt)
      end
    end

    private

    def retryable?(error)
      error.code == "proxy_unreachable" || error.status == 429 || error.status.to_i >= 500
    end

    def sync(workspace, attempt)
      CliProxy::Client.new(gateway: workspace.agent_gateway, workspace: workspace).provision_sync
    rescue CliProxy::Client::Error => e
      # Manifest HTTP failures (including upstream 429) are wrapped as 502 by the proxy.
      # Keep retrying transient failures: a fixed attempt limit strands large batches.
      # Back off beyond the manifest rate window, capped at fifteen minutes.
      if retryable?(e)
        self.class.set(wait: [ 65.seconds * (attempt + 1), 15.minutes ].min).perform_later(
          workspace.agent_id, workspace_id: workspace.id, attempt: attempt + 1
        )
      end
      Rails.logger.warn(
        "[AgentProvisioningSyncJob] workspace=#{workspace.id} #{e.code || e.status}: #{e.message}"
      )
    end
  end
end
