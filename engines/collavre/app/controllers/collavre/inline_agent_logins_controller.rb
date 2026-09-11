# frozen_string_literal: true

module Collavre
  class InlineAgentLoginsController < ApplicationController
    before_action :set_login
    before_action :require_manager, except: :show
    before_action :require_mutable_session, only: [ :create_session, :session, :submit, :cancel ]
    before_action :check_session, only: [ :session, :submit, :cancel ]
    rescue_from CliProxy::Client::Error, with: :render_proxy_error

    def show
      render :show, layout: false
    end

    def status
      engine = @login.client.engines.fetch("data", []).find { |row| row["engine"] == @login.engine }
      if engine
        engine = engine.merge("flows" => Array(engine["flows"]).presence || [ engine["flow"] ])
        engine["flows"] -= Array(engine["base_url_flows"])
      end
      snapshot = @login.session_snapshot
      render json: { engines: Array.wrap(engine), session: snapshot, resumed: @login.data["resumed"], authorized: @login.data["authorized"] }
    end

    def create_session
      response = @login.client.create_auth_session(@login.engine, flow: params[:flow].presence,
        provisioning_url: "#{request.base_url}#{agent_provision_manifest_path(agent_id: @login.agent.id, token: @login.workspace.manifest_token)}")
      @login.remember_session!(response)
      render json: response, status: :created
    end

    def session
      render json: @login.observe_session!(@login.client.auth_session(@login.engine, params[:session_id]), params[:session_id])
    end

    def submit
      # Custom provider URLs remain available on the full connection screen.
      # Inline login never accepts a caller-controlled destination.
      response = @login.client.submit_auth_session(@login.engine, params[:session_id], params[:auth_secret])
      render json: @login.observe_session!(response, params[:session_id])
    end

    def cancel
      response = @login.client.cancel_auth_session(@login.engine, params[:session_id])
      @login.observe_session!({ "status" => "cancelled" }, params[:session_id])
      render json: response
    end

    def resume
      @login.resume!
      render json: { resumed: true }
    end

    private

    def set_login
      response.headers["Cache-Control"] = "private, no-store"
      @comment = Comment.visible_to(Current.user).find(params[:comment_id])
      @login = CliProxy::InlineLogin.new(@comment, Current.user)
      return if action_name == "show" && @login.abandoned_card_visible?

      head :not_found unless @login.accessible?
    end

    def require_manager
      head :forbidden unless @login.manageable?
    end

    def require_mutable_session
      @login.check_session_mutable!
    end

    def check_session
      @login.check_session!(params[:session_id])
    end

    def render_proxy_error(error)
      render json: { error: { code: error.code, message: error.message } },
             status: error.status.to_i.between?(400, 599) ? error.status : :bad_gateway
    end
  end
end
