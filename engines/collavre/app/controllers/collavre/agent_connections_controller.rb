# frozen_string_literal: true

module Collavre
  class AgentConnectionsController < ApplicationController
    before_action :set_agent_and_workspace

    def show; end

    def status
      client = proxy_client
      engines = Array(client.engines["data"])
      engine_rows = engines.map do |engine|
        engine.merge("status" => client.engine_status(engine.fetch("engine")))
      rescue Collavre::CliProxy::Client::Error => e
        engine.merge("status" => { "state" => "unknown", "error" => e.message, "code" => e.code })
      end

      render json: {
        engines: engine_rows,
        provision: client.provision_status,
        workspace: {
          credential_id: @workspace.proxy_credential_id,
          workspace_id: @workspace.proxy_workspace_id,
          mode: @agent.agent_gateway.workspace_mode
        }
      }
    rescue Collavre::CliProxy::Client::Error => e
      render_proxy_error(e)
    end

    def create_auth_session
      response = proxy_client.create_auth_session(
        params[:engine],
        flow: params[:flow].presence,
        provisioning_url: manifest_url
      )
      render json: response, status: :created
    rescue Collavre::CliProxy::Client::Error => e
      render_proxy_error(e)
    end

    def auth_session
      render json: proxy_client.auth_session(params[:engine], params[:session_id])
    rescue Collavre::CliProxy::Client::Error => e
      render_proxy_error(e)
    end

    def submit_auth_session
      render json: proxy_client.submit_auth_session(params[:engine], params[:session_id], params[:auth_secret])
    rescue Collavre::CliProxy::Client::Error => e
      render_proxy_error(e)
    end

    def cancel_auth_session
      render json: proxy_client.cancel_auth_session(params[:engine], params[:session_id])
    rescue Collavre::CliProxy::Client::Error => e
      render_proxy_error(e)
    end

    def provision_sync
      render json: proxy_client.provision_sync
    rescue Collavre::CliProxy::Client::Error => e
      render_proxy_error(e)
    end

    def provision_approve
      render json: proxy_client.provision_approve(params[:type], params[:name])
    rescue Collavre::CliProxy::Client::Error => e
      render_proxy_error(e)
    end

    def provision_delete
      render json: proxy_client.provision_delete(params[:type], params[:name])
    rescue Collavre::CliProxy::Client::Error => e
      render_proxy_error(e)
    end

    def rotate_tokens
      @workspace.rotate_tokens!
      redirect_to agent_connection_user_path(@agent), notice: t("collavre.agent_connections.tokens_rotated")
    end

    private

    def set_agent_and_workspace
      @agent = Collavre::User.find(params[:user_id] || params[:id])
      return head :not_found unless @agent.cli_proxy_agent?
      return head :forbidden unless @agent.gateway_accessible_to?(Current.user)

      @workspace = Collavre::AgentWorkspace.resolve!(agent: @agent, user: Current.user)
      gateway = @workspace.agent_gateway
      if gateway.shared? && Current.user.id != @agent.created_by_id && !Current.user.system_admin?
        head :forbidden
      end
    rescue ArgumentError => error
      raise unless [ "Agent has no gateway", "Agent gateway is inactive" ].include?(error.message)

      head :service_unavailable
    end

    def proxy_client
      @proxy_client ||= Collavre::CliProxy::Client.new(gateway: @workspace.agent_gateway, workspace: @workspace)
    end

    def manifest_url
      "#{request.base_url}#{agent_provision_manifest_path(
        agent_id: @agent.id,
        token: @workspace.manifest_token
      )}"
    end

    def render_proxy_error(error)
      status = error.status.to_i.between?(400, 599) ? error.status : :bad_gateway
      render json: { error: { message: error.message, code: error.code } }, status: status
    end
  end
end
