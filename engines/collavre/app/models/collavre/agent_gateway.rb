# frozen_string_literal: true

module Collavre
  class AgentGateway < ApplicationRecord
    self.table_name = "agent_gateways"

    # Must match the proxy's USER_IDENTITY_HMAC_SECRET.
    MIN_IDENTITY_SECRET_BYTES = 32

    belongs_to :owner, class_name: "Collavre::User"
    has_many :agents, class_name: "Collavre::User", dependent: :restrict_with_error
    has_many :agent_workspaces, class_name: "Collavre::AgentWorkspace", dependent: :destroy

    enum :workspace_mode, { shared: 0, per_user: 1 }, default: :shared

    encrypts :admin_key, deterministic: false
    encrypts :completion_key, deterministic: false
    encrypts :identity_secret, deterministic: false

    normalizes :name, with: ->(value) { value.to_s.strip }
    normalizes :base_url, with: ->(value) { value.to_s.strip.sub(%r{/+\z}, "") }
    normalizes :tenant_id, with: ->(value) { value.to_s.strip }

    validates :name, :base_url, :admin_key, :completion_key, :tenant_id, presence: true
    validates :name, uniqueness: { scope: :owner_id }
    validates :tenant_id, format: { with: /\A[A-Za-z0-9][A-Za-z0-9._:@\/-]{0,199}\z/ }
    validate :base_url_is_http
    validate :base_url_is_safe_for_owner
    validate :identity_secret_is_usable
    after_update :reconcile_workspaces_after_gateway_change, if: :workspace_credentials_changed?

    scope :active, -> { where(active: true) }

    def completion_base_url
      "#{proxy_base_url}/v1"
    end

    def proxy_path(path)
      suffix = path.start_with?("/") ? path : "/#{path}"
      "#{proxy_base_url}#{suffix}"
    end

    # Desktop-managed gateways are created only by the signed native setup
    # handoff and always target the local proxy. They remain usable when their
    # original owner later loses the system administrator role.
    def desktop_loopback?
      return false unless desktop_managed?

      uri = URI.parse(base_url.to_s)
      uri.scheme == "http" &&
        uri.host == "127.0.0.1" &&
        uri.port.present? &&
        uri.userinfo.blank? &&
        uri.query.blank? &&
        uri.fragment.blank?
    rescue URI::InvalidURIError
      false
    end

    private

    def proxy_base_url
      base_url.delete_suffix("/v1")
    end

    def base_url_is_http
      uri = URI.parse(base_url.to_s)
      return if uri.is_a?(URI::HTTP) && uri.host.present? && uri.userinfo.blank? && uri.query.blank? && uri.fragment.blank?

      errors.add(:base_url, :invalid)
    rescue URI::InvalidURIError
      errors.add(:base_url, :invalid)
    end

    def base_url_is_safe_for_owner
      return if owner&.system_admin?
      return if desktop_loopback?
      return if CliProxy::EndpointPolicy.new.safe_literal?(base_url)

      errors.add(:base_url, :unsafe)
    end

    def identity_secret_is_usable
      if identity_secret.blank?
        # A single-agent shared gateway may fall back to the proxy's unscoped workspace.
        errors.add(:identity_secret, :blank) if per_user? || agents.many?
        return
      end

      return if identity_secret.to_s.bytesize >= MIN_IDENTITY_SECRET_BYTES

      errors.add(:identity_secret, :too_short, count: MIN_IDENTITY_SECRET_BYTES)
    end

    def workspace_credentials_changed?
      saved_change_to_base_url? || saved_change_to_tenant_id? || saved_change_to_workspace_mode? || deactivated?
    end

    def deactivated?
      saved_change_to_active? && !active?
    end

    def reconcile_workspaces_after_gateway_change
      if saved_change_to_base_url? || saved_change_to_tenant_id? || deactivated?
        agent_workspaces.destroy_all
        return
      end

      agents.find_each do |agent|
        workspaces = agent_workspaces.where(agent: agent)
        next unless workspaces.exists?

        workspaces.destroy_all
        next unless active?

        AgentWorkspace.resolve!(agent: agent, user: per_user? ? agent.creator : nil)
      end
    end
  end
end
