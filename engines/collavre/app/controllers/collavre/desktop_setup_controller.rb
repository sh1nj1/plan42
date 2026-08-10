# frozen_string_literal: true

module Collavre
  # First-run flow for the desktop CLI Proxy. Credential generation and the
  # local proxy process live in Tauri; this controller only persists the
  # resulting gateway after verifying a short-lived, local-only handoff token.
  class DesktopSetupController < ApplicationController
    allow_unauthenticated_access only: %i[show create_account]

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
      return if @account_required

      # Recovery is entered without a step after native setup fails. An
      # authenticated owner must resume at installation rather than see the
      # sign-in-only account panel.
      if @user
        @step = "install" if @step == "account"
        return
      end

      # A failed native registration leaves the proxy installed but incomplete.
      # Preserve the exact setup destination through login so the local owner
      # can retry without deleting Keychain entries or app data.
      @step = "install" if @step == "account"
      session[:return_to_after_authenticating] = collavre.desktop_setup_path(step: @step)
      redirect_to collavre.new_session_path
    end

    def create_account
      return unless require_desktop_mode!
      return unless require_loopback!

      @user = Collavre::User.new(account_params)
      Collavre::User.transaction do
        unless @user.save
          @step = "account"
          @account_required = true
          render :show, status: :unprocessable_entity
          return
        end

        # The absence check is part of the UPDATE itself. Two overlapping local
        # signups can both save, but only one can become the first administrator.
        admin_exists = Collavre::User.where(system_admin: true).arel.exists
        promoted = Collavre::User.where(id: @user.id)
          .where(admin_exists.not)
          .update_all(email_verified_at: Time.current, system_admin: true)
        raise FirstAdministratorAlreadyCreated unless promoted == 1
      end
      start_new_session_for(@user)
      redirect_to collavre.desktop_setup_path(step: :install)
    rescue FirstAdministratorAlreadyCreated
      redirect_to collavre.new_session_path, alert: t("collavre.desktop_setup.account.already_created")
    end

    def registration_token
      return unless require_desktop_mode!
      return unless require_loopback!
      unless Current.user&.system_admin?
        head :forbidden
        return
      end

      render json: { token: registration_verifier.generate({ user_id: Current.user.id, expires_at: 5.minutes.from_now.to_i }) }
    end

    private

    FirstAdministratorAlreadyCreated = Class.new(StandardError)

    def account_params
      params.require(:admin).permit(:name, :email, :password, :password_confirmation)
    end

    def registration_verifier
      Rails.application.message_verifier("desktop-gateway-registration")
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

    def require_desktop_mode!
      return true if Rails.application.config.x.desktop_proxy_setup == true

      head :not_found
      false
    end
  end
end
