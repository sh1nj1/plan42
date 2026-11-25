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
      # Retained workspaces still need Fast disabled after the agent leaves CLI Proxy.
      gateway = agent&.agent_gateway
      return unless gateway
      return release_gateway(agent, gateway) unless gateway.active?

      workspaces = agent.agent_workspaces.where(agent_gateway_id: agent.agent_gateway_id)
      workspaces = workspaces.where(id: workspace_id) if workspace_id
      workspaces.find_each do |workspace|
        sync(workspace, attempt)
      end
      release_gateway(agent, agent.agent_gateway)
    end

    private

    # Follow workspace resolution's gateway -> agent lock order. Recheck after
    # the network call so a return to CLI Proxy or reassignment is not detached.
    # Successful workspaces are removed individually; failed ones retain their
    # manifest and token until their retry succeeds.
    def release_gateway(agent, gateway, workspace: nil)
      gateway.with_lock do
        agent.with_lock do
          next if agent.cli_proxy_agent? || agent.agent_gateway_id != gateway.id

          agent.agent_workspaces.destroy_all unless gateway.active?
          agent.agent_workspaces.where(id: workspace.id).destroy_all if workspace
          agent.update!(agent_gateway: nil) unless agent.agent_workspaces.exists?
        end
      end
    end

    def retryable?(error)
      error.code == "proxy_unreachable" || error.status == 429 || error.status.to_i >= 500
    end

    def sync(workspace, attempt)
      status = CliProxy::Client.new(gateway: workspace.agent_gateway, workspace: workspace).provision_sync
      if status.is_a?(Hash) && status["last_error"].present?
        raise CliProxy::Client::Error.new("Provisioning sync incomplete", status: 502)
      end
      release_gateway(workspace.agent, workspace.agent_gateway, workspace: workspace)
    rescue CliProxy::Client::Error => e
      handle_failure(workspace, attempt, e)
    end

    def handle_failure(workspace, attempt, error)
      # Manifest HTTP failures (including upstream 429) are wrapped as 502 by the proxy.
      # Keep retrying transient failures: a fixed attempt limit strands large batches.
      # Back off beyond the manifest rate window, capped at fifteen minutes.
      if retryable?(error)
        self.class.set(wait: [ 65.seconds * (attempt + 1), 15.minutes ].min).perform_later(
          workspace.agent_id, workspace_id: workspace.id, attempt: attempt + 1
        )
      else
        release_gateway(workspace.agent, workspace.agent_gateway, workspace: workspace)
        Rails.logger.warn("[AgentProvisioningSyncJob] workspace=#{workspace.id} Sync unconfirmed; retired workspace cleanup attempted")
      end
      Rails.logger.warn(
        "[AgentProvisioningSyncJob] workspace=#{workspace.id} #{error.code || error.status}: #{error.message}"
      )
    end
  end
end
