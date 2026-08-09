# frozen_string_literal: true

require "digest"

module Collavre
  class AgentWorkspace < ApplicationRecord
    self.table_name = "agent_workspaces"

    belongs_to :agent, class_name: "Collavre::User"
    belongs_to :user, class_name: "Collavre::User", optional: true
    belongs_to :agent_gateway, class_name: "Collavre::AgentGateway"

    encrypts :manifest_token, deterministic: false
    encrypts :callback_token, deterministic: false

    # Mirrors the proxy's STABLE_ID_RE: the credential axis selects the OS worker.
    CREDENTIAL_ID_FORMAT = /\A[A-Za-z0-9][A-Za-z0-9._:@\/-]{0,199}\z/
    # Mirrors the proxy's WORKSPACE_ID_RE. Narrower than the credential format
    # because this value becomes one path segment below the worker's HOME, so
    # "/" and "." must stay out of it.
    WORKSPACE_ID_FORMAT = /\A[A-Za-z0-9][A-Za-z0-9_:@-]{0,199}\z/

    validates :proxy_credential_id, :proxy_workspace_id, :manifest_token,
              :manifest_token_digest, :callback_token, presence: true
    validates :proxy_credential_id, format: { with: CREDENTIAL_ID_FORMAT }
    validates :proxy_workspace_id, format: { with: WORKSPACE_ID_FORMAT }
    validates :manifest_token_digest, uniqueness: true

    before_validation :derive_manifest_token_digest, if: :will_save_change_to_manifest_token?
    before_destroy :revoke_callback_token

    class << self
      def resolve!(agent:, user:)
        loop do
          gateway_id = agent.class.where(id: agent.id).pick(:agent_gateway_id)
          raise ArgumentError, "Agent has no gateway" unless gateway_id

          gateway = Collavre::AgentGateway.find(gateway_id)
          workspace = gateway.with_lock do
            agent.with_lock do
              # User validation takes the gateway lock before updating the agent.
              # Use the same lock order, then verify the association under both
              # locks. A concurrent reassignment makes this attempt retry against
              # the newly persisted gateway instead of creating stale credentials.
              next unless agent.agent_gateway_id == gateway.id

              raise ArgumentError, "Agent gateway is inactive" unless gateway.active?

              gateway.shared? ? resolve_shared!(agent, gateway) : resolve_per_user!(agent, user, gateway)
            end
          end

          return workspace if workspace
        end
      end

      def find_by_manifest_token!(agent_id:, token:)
        supplied = token.to_s
        workspace = find_by!(agent_id: agent_id, manifest_token_digest: manifest_digest(supplied))
        return workspace if ActiveSupport::SecurityUtils.secure_compare(supplied, workspace.manifest_token.to_s)

        raise ActiveRecord::RecordNotFound
      end

      def manifest_digest(token)
        Digest::SHA256.hexdigest(token)
      end

      # The workspace axis is always the agent: skills, workspace config, and the
      # provisioning lockfile are per agent regardless of the gateway mode.
      def proxy_workspace_id_for(agent)
        "agent-#{agent.id}"
      end

      # The credential axis selects the proxy worker that holds the engine
      # logins. A per-user gateway keys it by Collavre user so one login covers
      # every agent that user reaches; a shared gateway keys it by agent so all
      # of its users keep sharing the one login.
      def proxy_credential_id_for(agent, user)
        user ? "user-#{user.id}" : "agent-#{agent.id}"
      end

      # Nothing here reads proxy_user_id; it is written so a process still
      # running the pre-split code can resolve rows this release creates —
      # the previous container during a Kamal rollout, or the whole app after
      # a rollback. Drop this together with the column in the contract
      # migration that follows this release.
      def legacy_proxy_user_id_for(agent, user)
        return "agent-#{agent.id}" unless user

        "agent-#{agent.id}--user-#{user.id}"
      end

      private

      def resolve_shared!(agent, gateway)
        existing = find_by(agent: agent, agent_gateway: gateway, user_id: nil)
        return existing if identity_current?(existing, agent, nil)

        existing&.destroy!
        create_workspace!(agent: agent, user: nil, gateway: gateway)
      rescue ActiveRecord::RecordNotUnique
        find_by!(agent: agent, agent_gateway: gateway, user_id: nil)
      end

      def resolve_per_user!(agent, user, gateway)
        raise ArgumentError, "A user is required for a per-user workspace" unless user

        existing = find_by(agent: agent, user: user, agent_gateway: gateway)
        return existing if identity_current?(existing, agent, user)

        existing&.destroy!

        if user.id == agent.created_by_id
          find_by(agent: agent, agent_gateway: gateway, user_id: nil)&.destroy!
        end

        create_workspace!(agent: agent, user: user, gateway: gateway)
      rescue ActiveRecord::RecordNotUnique
        find_by!(agent: agent, user: user, agent_gateway: gateway)
      end

      # A row minted under an older identity scheme addresses a proxy workspace
      # that no longer matches its agent/user pair, so it is replaced rather than
      # reused — its credentials would resolve to the wrong worker or directory.
      def identity_current?(workspace, agent, user)
        return false unless workspace

        workspace.proxy_workspace_id == proxy_workspace_id_for(agent) &&
          workspace.proxy_credential_id == proxy_credential_id_for(agent, user)
      end

      def create_workspace!(agent:, user:, gateway:)
        transaction do
          callback_token = issue_callback_token!(gateway: gateway, owner: user || agent)

          create!(
            agent: agent,
            user: user,
            agent_gateway: gateway,
            proxy_workspace_id: proxy_workspace_id_for(agent),
            proxy_credential_id: proxy_credential_id_for(agent, user),
            proxy_user_id: legacy_proxy_user_id_for(agent, user),
            manifest_token: SecureRandom.urlsafe_base64(32),
            callback_token: callback_token
          )
        end
      end

      def issue_callback_token!(gateway:, owner:)
        application = Doorkeeper::Application.find_or_create_by!(
          owner: gateway.owner,
          name: "Collavre Agent Gateway",
          redirect_uri: "urn:ietf:wg:oauth:2.0:oob"
        ) do |app|
          app.scopes = "public"
          app.confidential = true
        end

        access_token = Doorkeeper::AccessToken.create!(
          application: application,
          resource_owner_id: owner.id,
          scopes: "public",
          expires_in: nil,
          use_refresh_token: false
        )
        plaintext = access_token.token
        access_token.update_column(:token, Collavre::HashedAccessTokenLookup.encode(plaintext))

        plaintext
      end
    end

    def config_payload(base_url:)
      { url: base_url.sub(%r{/+\z}, ""), token: callback_token }
    end

    def rotate_tokens!
      gateway = agent_gateway
      gateway.with_lock do
        workspace_agent = agent
        workspace_agent.with_lock do
          raise ActiveRecord::RecordNotFound unless workspace_agent.agent_gateway_id == gateway.id
          raise ArgumentError, "Agent gateway is inactive" unless gateway.active?

          with_lock do
            raise ActiveRecord::RecordNotFound unless agent_gateway_id == gateway.id

            old_access_token = Doorkeeper::AccessToken.by_token(callback_token)
            new_callback_token = self.class.send(:issue_callback_token!, gateway: gateway, owner: user || workspace_agent)
            update!(callback_token: new_callback_token)
            old_access_token&.revoke
          end
        end
      end

      self
    end

    private

    def derive_manifest_token_digest
      self.manifest_token_digest = self.class.manifest_digest(manifest_token.to_s)
    end

    def revoke_callback_token
      Doorkeeper::AccessToken.by_token(callback_token)&.revoke
    end
  end
end
