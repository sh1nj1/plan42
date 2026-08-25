# frozen_string_literal: true

module Collavre
  class AgentGateway < ApplicationRecord
    self.table_name = "agent_gateways"

    # Must match the proxy's USER_IDENTITY_HMAC_SECRET.
    MIN_IDENTITY_SECRET_BYTES = 32
    DESKTOP_NATIVE_CREDENTIAL_ATTRIBUTES = %i[admin_key completion_key identity_secret].freeze

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

    validates :name, :base_url, :admin_key, :tenant_id, presence: true
    validates :name, uniqueness: { scope: :owner_id }
    validates :tenant_id, format: { with: /\A[A-Za-z0-9][A-Za-z0-9._:@\/-]{0,199}\z/ }
    validate :base_url_is_http
    validate :base_url_is_safe_for_owner
    validate :desktop_managed_base_url_is_immutable
    validate :desktop_managed_credentials_are_immutable
    validate :desktop_managed_gateway_uses_shared_workspace
    validate :identity_secret_is_usable
    validate :completion_key_is_present_when_assigned_to_agents
    around_update :serialize_completion_key_removal
    before_update :validate_completion_key_removal_under_lock
    after_update :reconcile_workspaces_after_gateway_change, if: :workspace_credentials_changed?

    scope :active, -> { where(active: true) }

    def chat_capable?
      completion_key.present?
    end

    def completion_base_url
      "#{proxy_base_url}/v1"
    end

    def proxy_path(path)
      suffix = path.start_with?("/") ? path : "/#{path}"
      "#{proxy_base_url}#{suffix}"
    end

    # The signed native setup handoff is the only flow permitted to retarget a
    # desktop-managed gateway. Its loopback exception must not be reusable by
    # an owner editing the gateway through the regular settings UI.
    def update_from_desktop_registration!(attributes)
      @desktop_registration_update = true
      update!(attributes)
    ensure
      @desktop_registration_update = false
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

    def desktop_managed_base_url_is_immutable
      return unless persisted? && desktop_managed? && will_save_change_to_base_url?
      return if @desktop_registration_update

      errors.add(:base_url, :immutable)
    end

    # Keychain is the source of truth for the local proxy credentials. The
    # regular Rails settings form cannot synchronize it, so only the signed
    # native registration handoff may rotate these values.
    def desktop_managed_credentials_are_immutable
      return unless persisted? && desktop_managed?
      return if @desktop_registration_update

      DESKTOP_NATIVE_CREDENTIAL_ATTRIBUTES.each do |attribute|
        next unless public_send("will_save_change_to_#{attribute}?")

        errors.add(attribute, :immutable)
      end
    end

    # The macOS bundle deliberately runs one shared local proxy. Per-user
    # routing requires a worker and identity secret that desktop never starts.
    def desktop_managed_gateway_uses_shared_workspace
      return unless desktop_managed? && !shared?

      errors.add(:workspace_mode, :desktop_shared_only)
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

    def completion_key_is_present_when_assigned_to_agents
      return if completion_key.present? || !agents.exists?

      errors.add(:completion_key, :required_for_agents)
    end

    # An agent assignment and key removal both depend on the same invariant.
    # Re-check under the gateway row lock so two requests that validated a
    # previously key-bearing, unassigned gateway cannot both commit.
    def serialize_completion_key_removal
      return yield unless will_save_change_to_completion_key? && completion_key.blank?

      locked_gateway = self.class.find(id)
      locked_gateway.with_lock do
        begin
          @completion_key_removal_lock = locked_gateway
          yield
        ensure
          @completion_key_removal_lock = nil
        end
      end
    end

    def validate_completion_key_removal_under_lock
      return unless @completion_key_removal_lock&.agents&.exists?

      errors.add(:completion_key, :required_for_agents)
      throw :abort
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
