# frozen_string_literal: true

require "ipaddr"

module Collavre
  # Stateless, loopback-only native handoff for the desktop shell. It has no
  # browser session or CSRF cookie; authorization is the signed, short-lived
  # grant issued to the authenticated desktop webview.
  class DesktopGatewayRegistrationsController < ActionController::API
    # Native code calls this before it creates Keychain credentials or starts
    # the local proxy. The signed token is the administrator's short-lived
    # setup consent and remains the sole authorization for the sessionless
    # loopback handoff.
    def validate_registration_grant
      return unless require_desktop_mode!
      return unless require_loopback!

      registration_owner!
      head :no_content
    rescue ActionController::ParameterMissing, ActiveSupport::MessageVerifier::InvalidSignature => e
      render json: { error: e.message }, status: :unprocessable_entity
    end

    def create
      return unless require_desktop_mode!
      return unless require_loopback!

      registration_owner = registration_owner!
      # A desktop has one local proxy, not one proxy per administrator. The
      # persisted desktop_managed marker identifies it independently of its
      # user-editable display name and owner during recovery.
      gateway = Collavre::AgentGateway.find_or_initialize_by(desktop_managed: true)
      gateway.owner ||= registration_owner
      gateway.name ||= available_desktop_gateway_name(gateway.owner)
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
    rescue ActiveRecord::RecordNotUnique
      # Concurrent first-run handoffs can both observe no marked gateway. Once
      # one creates it, reload that durable identity and apply this handoff.
      raise if @retried_after_gateway_insert

      @retried_after_gateway_insert = true
      retry
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
      agent = owner.created_ai_users.find_or_initialize_by(desktop_preset_adapter: adapter)
      if agent.new_record?
        agent.assign_attributes(
          name: name,
          password: SecureRandom.hex(36),
          email: available_desktop_preset_email(email, gateway),
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

    def available_desktop_preset_email(email, gateway)
      return email unless Collavre::User.exists?(email: email)

      local_part, domain = email.split("@", 2)
      base = "#{local_part}+desktop-#{gateway.id}"
      candidate = "#{base}@#{domain}"
      return candidate unless Collavre::User.exists?(email: candidate)

      suffix = (2..).find do |number|
        !Collavre::User.exists?(email: "#{base}-#{number}@#{domain}")
      end
      "#{base}-#{suffix}@#{domain}"
    end

    def available_desktop_gateway_name(owner)
      base_name = DesktopSetupController::DESKTOP_GATEWAY_NAME
      return base_name unless owner.owned_agent_gateways.exists?(name: base_name)

      suffix = (2..).find { |number| !owner.owned_agent_gateways.exists?(name: "#{base_name} (#{number})") }
      "#{base_name} (#{suffix})"
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
