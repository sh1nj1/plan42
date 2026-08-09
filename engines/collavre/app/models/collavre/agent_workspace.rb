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

    validates :proxy_user_id, :manifest_token, :manifest_token_digest, :callback_token, presence: true
    validates :proxy_user_id, format: { with: /\A[A-Za-z0-9][A-Za-z0-9._:@\/-]{0,199}\z/ }
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

      private

      def resolve_shared!(agent, gateway)
        find_by(agent: agent, agent_gateway: gateway, user_id: nil) ||
          create_workspace!(agent: agent, user: nil, gateway: gateway, proxy_user_id: "agent-#{agent.id}")
      rescue ActiveRecord::RecordNotUnique
        find_by!(agent: agent, agent_gateway: gateway, user_id: nil)
      end

      def resolve_per_user!(agent, user, gateway)
        raise ArgumentError, "A user is required for a per-user workspace" unless user

        existing = find_by(agent: agent, user: user, agent_gateway: gateway)
        return existing if existing

        if user.id == agent.created_by_id
          shared = find_by(agent: agent, agent_gateway: gateway, user_id: nil)
          return shared.reassign_principal!(user: user) if shared
        end

        create_workspace!(
          agent: agent,
          user: user,
          gateway: gateway,
          proxy_user_id: "agent-#{agent.id}--user-#{user.id}"
        )
      rescue ActiveRecord::RecordNotUnique
        find_by!(agent: agent, user: user, agent_gateway: gateway)
      end

      def create_workspace!(agent:, user:, gateway:, proxy_user_id:)
        transaction do
          callback_token = issue_callback_token!(gateway: gateway, owner: user || agent)

          create!(
            agent: agent,
            user: user,
            agent_gateway: gateway,
            proxy_user_id: proxy_user_id,
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

    def reassign_principal!(user:)
      with_lock do
        return self if user_id == user&.id

        old_access_token = Doorkeeper::AccessToken.by_token(callback_token)
        new_callback_token = self.class.send(:issue_callback_token!, gateway: agent_gateway, owner: user || agent)
        update!(user: user, callback_token: new_callback_token)
        old_access_token&.revoke
      end

      self
    end

    def rotate_tokens!
      with_lock do
        old_access_token = Doorkeeper::AccessToken.by_token(callback_token)
        new_callback_token = self.class.send(:issue_callback_token!, gateway: agent_gateway, owner: user || agent)
        update!(callback_token: new_callback_token)
        old_access_token&.revoke
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
