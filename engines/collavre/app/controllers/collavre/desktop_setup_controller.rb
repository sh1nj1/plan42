# frozen_string_literal: true

module Collavre
  # First-run flow for the desktop CLI Proxy. Credential generation and the
  # local proxy process live in Tauri; this controller only persists the
  # resulting gateway after verifying a short-lived, local-only handoff token.
  class DesktopSetupController < ApplicationController
    allow_unauthenticated_access only: %i[show create_account register_gateway]
    skip_forgery_protection only: :register_gateway

    STEPS = %w[account install adapters ready].freeze
    DESKTOP_GATEWAY_NAME = "Collavre Desktop CLI Proxy"
    PRESETS = {
      "claude" => [ "Claude Code", "collavre-desktop-claude-code@ai.local", "paperclip/claude_local" ],
      "codex" => [ "Codex", "collavre-desktop-codex@ai.local", "paperclip/codex_local" ]
    }.freeze

    def show
      @step = params[:step].to_s
      @step = STEPS.first unless STEPS.include?(@step)
      @user = Current.user
      @account_required = !Collavre::User.where(system_admin: true).exists?
      return if @account_required || @user

      # A failed native registration leaves the proxy installed but incomplete.
      # Preserve the exact setup destination through login so the local owner
      # can retry without deleting Keychain entries or app data.
      @step = "install" if @step == "account"
      session[:return_to_after_authenticating] = collavre.desktop_setup_path(step: @step)
      redirect_to collavre.new_session_path
    end

    def create_account
      return unless require_loopback!
      if Collavre::User.where(system_admin: true).exists?
        redirect_to collavre.new_session_path, alert: t("collavre.desktop_setup.account.already_created")
        return
      end

      @user = Collavre::User.new(account_params)
      Collavre::User.transaction do
        unless @user.save
          @step = "account"
          @account_required = true
          render :show, status: :unprocessable_entity
          return
        end

        @user.update_columns(email_verified_at: Time.current, system_admin: true)
      end
      start_new_session_for(@user)
      redirect_to collavre.desktop_setup_path(step: :install)
    end

    # The browser receives only a signed, five-minute registration grant. The
    # native command consumes it while sending Keychain-only secrets directly to
    # this loopback endpoint; secrets never enter the DOM or JavaScript response.
    def registration_token
      return unless require_loopback!
      unless Current.user&.system_admin?
        head :forbidden
        return
      end

      render json: { token: registration_verifier.generate({ user_id: Current.user.id, expires_at: 5.minutes.from_now.to_i }) }
    end

    def register_gateway
      return unless require_loopback!
      owner = registration_owner!
      gateway = owner.owned_agent_gateways.find_or_initialize_by(name: DESKTOP_GATEWAY_NAME)
      gateway.assign_attributes(
        base_url: "http://127.0.0.1:#{proxy_port}",
        admin_key: params.require(:admin_key),
        completion_key: params.require(:completion_key),
        identity_secret: params.require(:identity_secret),
        tenant_id: "collavre-desktop",
        workspace_mode: :shared,
        active: true
      )

      Collavre::AgentGateway.transaction do
        gateway.save!
        detected_adapters.each { |adapter| provision_preset!(owner, gateway, adapter) }
      end
      render json: { gateway_id: gateway.id, adapters: detected_adapters }, status: :created
    rescue ActiveRecord::RecordInvalid => e
      render json: { error: e.record.errors.full_messages.to_sentence }, status: :unprocessable_entity
    rescue ActionController::ParameterMissing, ActiveSupport::MessageVerifier::InvalidSignature => e
      render json: { error: e.message }, status: :unprocessable_entity
    end

    private

    def account_params
      params.require(:admin).permit(:name, :email, :password, :password_confirmation)
    end

    def proxy_port
      Integer(params.require(:proxy_port).to_s, 10).tap do |port|
        raise ActionController::ParameterMissing, :proxy_port unless (1..65_535).cover?(port)
      end
    rescue ArgumentError
      raise ActionController::ParameterMissing, :proxy_port
    end

    def detected_adapters
      Array(params[:adapters]).map(&:to_s).intersection(PRESETS.keys)
    end

    def provision_preset!(owner, gateway, adapter)
      name, email, model = PRESETS.fetch(adapter)
      agent = owner.created_ai_users.find_or_initialize_by(email: email)
      agent.assign_attributes(
        name: name,
        password: SecureRandom.hex(36),
        email_verified_at: Time.current,
        llm_vendor: "cli_proxy",
        llm_model: model,
        agent_gateway: gateway,
        searchable: false,
        tools: []
      )
      agent.save!
    end

    def registration_verifier
      Rails.application.message_verifier("desktop-gateway-registration")
    end

    def registration_owner!
      payload = registration_verifier.verify(params.require(:registration_token))
      raise ActiveSupport::MessageVerifier::InvalidSignature if payload.fetch("expires_at").to_i < Time.current.to_i

      Collavre::User.find(payload.fetch("user_id")).tap do |user|
        raise ActiveSupport::MessageVerifier::InvalidSignature unless user.system_admin?
      end
    end

    def require_loopback!
      addr = IPAddr.new(request.remote_addr.to_s)
      addr = addr.native if addr.respond_to?(:ipv4_mapped?) && addr.ipv4_mapped?
      return true if addr.loopback?

      head :forbidden
      false
    rescue IPAddr::InvalidAddressError
      head :forbidden
      false
    end
  end
end
