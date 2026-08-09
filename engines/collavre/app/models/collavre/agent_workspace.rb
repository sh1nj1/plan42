# frozen_string_literal: true

module Collavre
  class AgentWorkspace < ApplicationRecord
    self.table_name = "agent_workspaces"

    belongs_to :agent, class_name: "Collavre::User"
    belongs_to :user, class_name: "Collavre::User", optional: true
    belongs_to :agent_gateway, class_name: "Collavre::AgentGateway"

    encrypts :callback_token, deterministic: false

    validates :proxy_user_id, :manifest_token, :callback_token, presence: true
    validates :proxy_user_id, format: { with: /\A[A-Za-z0-9][A-Za-z0-9._:@\/-]{0,199}\z/ }
    validates :manifest_token, uniqueness: true

    before_destroy :revoke_callback_token

    class << self
      def resolve!(agent:, user:)
        gateway = agent.agent_gateway or raise ArgumentError, "Agent has no gateway"
        raise ArgumentError, "Agent gateway is inactive" unless gateway.active?

        gateway.shared? ? resolve_shared!(agent, gateway) : resolve_per_user!(agent, user, gateway)
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
          return shared.update!(user: user) && shared if shared
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
        token_owner = user || agent
        access_token = issue_callback_token!(gateway: gateway, owner: token_owner)

        create!(
          agent: agent,
          user: user,
          agent_gateway: gateway,
          proxy_user_id: proxy_user_id,
          manifest_token: SecureRandom.urlsafe_base64(32),
          callback_token: access_token.token
        )
      rescue StandardError
        access_token&.revoke
        raise
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

        Doorkeeper::AccessToken.create!(
          application: application,
          resource_owner_id: owner.id,
          scopes: "public",
          expires_in: nil,
          use_refresh_token: false
        )
      end
    end

    def config_payload(base_url:)
      { url: base_url.sub(%r{/+\z}, ""), token: callback_token }
    end

    def rotate_tokens!
      old_token = callback_token
      access_token = self.class.send(:issue_callback_token!, gateway: agent_gateway, owner: user || agent)
      update!(manifest_token: SecureRandom.urlsafe_base64(32), callback_token: access_token.token)
      Doorkeeper::AccessToken.by_token(old_token)&.revoke
      self
    end

    private

    def revoke_callback_token
      Doorkeeper::AccessToken.by_token(callback_token)&.revoke
    end
  end
end
