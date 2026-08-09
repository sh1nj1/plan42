# frozen_string_literal: true

module Collavre
  class AgentGatewaysController < ApplicationController
    before_action :set_gateway, only: %i[edit update destroy check]

    def index
      @agent_gateways = Current.user.owned_agent_gateways.order(:name)
    end

    def new
      @agent_gateway = Current.user.owned_agent_gateways.new
    end

    def create
      @agent_gateway = Current.user.owned_agent_gateways.new(gateway_params)
      if @agent_gateway.save
        redirect_to agent_gateways_path, notice: t("collavre.agent_gateways.created")
      else
        render :new, status: :unprocessable_entity
      end
    end

    def edit; end

    def update
      attributes = gateway_params
      %i[admin_key completion_key identity_secret].each do |key|
        attributes.delete(key) if attributes[key].blank?
      end

      if @agent_gateway.update(attributes)
        redirect_to agent_gateways_path, notice: t("collavre.agent_gateways.updated")
      else
        render :edit, status: :unprocessable_entity
      end
    end

    def destroy
      if @agent_gateway.destroy
        redirect_to agent_gateways_path, notice: t("collavre.agent_gateways.destroyed")
      else
        redirect_to agent_gateways_path, alert: t("collavre.agent_gateways.in_use")
      end
    end

    def check
      if @agent_gateway.completion_key.present?
        data = connection_check_client(user_key: @agent_gateway.completion_key).engines
        render_connection_check(data, identity: "completion_key")
      else
        check_with_workspace_or_admin
      end
    rescue Collavre::CliProxy::Client::Error => e
      return retry_connection_check_with_workspace if e.code == "user_identity_required"

      render json: { ok: false, error: e.message, code: e.code }, status: :bad_gateway
    end

    private

    def set_gateway
      @agent_gateway = Current.user.owned_agent_gateways.find(params[:id])
    end

    def gateway_params
      params.require(:agent_gateway).permit(
        :name, :base_url, :admin_key, :completion_key, :identity_secret,
        :tenant_id, :workspace_mode, :active
      )
    end

    def retry_connection_check_with_workspace
      workspace = connection_check_workspace
      return render_identity_unverified unless workspace

      data = connection_check_client(workspace: workspace).engines
      render_connection_check(data, identity: "workspace")
    rescue Collavre::CliProxy::Client::Error => e
      render json: { ok: false, error: e.message, code: e.code }, status: :bad_gateway
    end

    def check_with_workspace_or_admin
      workspace = connection_check_workspace
      return retry_connection_check_with_workspace if workspace

      data = connection_check_client.engines
      render_identity_unverified(data)
    end

    def connection_check_workspace
      scope = @agent_gateway.agent_workspaces.order(:id)
      return scope.find_by(user: Current.user) if @agent_gateway.per_user?

      scope.joins(:agent).find_by(user_id: nil, users: { created_by_id: Current.user.id })
    end

    def connection_check_client(user_key: nil, workspace: nil)
      Collavre::CliProxy::Client.new(gateway: @agent_gateway, user_key: user_key, workspace: workspace)
    end

    def render_connection_check(data, identity:)
      render json: {
        ok: true,
        identity_verified: true,
        identity: identity,
        engines: Array(data["data"]).pluck("engine")
      }
    end

    def render_identity_unverified(data = {})
      render json: {
        ok: true,
        identity_verified: false,
        engines: Array(data["data"]).pluck("engine"),
        warning: t("collavre.agent_gateways.identity_unverified")
      }
    end
  end
end
