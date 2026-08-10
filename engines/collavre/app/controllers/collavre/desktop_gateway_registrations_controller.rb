# frozen_string_literal: true

require "ipaddr"

module Collavre
  # Stateless, loopback-only native handoff for the desktop shell. It has no
  # browser session or CSRF cookie; authorization is the signed, short-lived
  # grant issued to the authenticated desktop webview.
  class DesktopGatewayRegistrationsController < ActionController::API
    def create
      return unless require_desktop_mode!
      return unless require_loopback!

      registration_owner = registration_owner!
      # A desktop has one local proxy, not one proxy per administrator. The
      # persisted desktop_managed marker identifies it independently of its
      # user-editable display name and owner during recovery.
      gateway = Collavre::AgentGateway.find_or_initialize_by(desktop_managed: true)
      gateway.owner ||= registration_owner
      gateway.name ||= DesktopSetupController::DESKTOP_GATEWAY_NAME
      owner = gateway.owner
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

    def proxy_port
      Integer(params.require(:proxy_port).to_s, 10).tap do |port|
        raise ActionController::ParameterMissing, :proxy_port unless (1..65_535).cover?(port)
      end
    rescue ArgumentError
      raise ActionController::ParameterMissing, :proxy_port
    end

    def detected_adapters
      Array(params[:adapters]).map(&:to_s).intersection(DesktopSetupController::PRESETS.keys)
    end

    def provision_preset!(owner, gateway, adapter)
      name, email, model = DesktopSetupController::PRESETS.fetch(adapter)
      agent = owner.created_ai_users.find_or_initialize_by(email: email)
      if agent.new_record?
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
      Collavre::Contact.ensure(user: owner, contact_user: agent)
    end

    def registration_owner!
      payload = Rails.application.message_verifier("desktop-gateway-registration").verify(params.require(:registration_token))
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

    def require_desktop_mode!
      return true if Rails.application.config.x.desktop_proxy_setup == true

      head :not_found
      false
    end
  end
end
