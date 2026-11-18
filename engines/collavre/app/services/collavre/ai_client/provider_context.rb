# frozen_string_literal: true

module Collavre
  class AiClient
    module ProviderContext
      private

      # RubyLLM duplicates the global configuration; credentials and timeouts
      # stay isolated between concurrent agent requests.
      def build_llm_context
        @ruby_llm_context = RubyLLM.context do |config|
          configure_provider(config)
          config.request_timeout = effective_request_timeout_seconds
        end
      end

      def configure_provider(config)
        case vendor
        when "openai", "cli_proxy" then configure_openai(config)
        when "typesafe"
          config.typesafe_api_key = llm_api_key
          config.typesafe_api_base = gateway_url if gateway_url.present?
        when "anthropic"
          config.anthropic_api_key = llm_api_key.presence || IntegrationSettings.fetch(:anthropic_api_key)
        else
          config.gemini_api_key = llm_api_key.presence || IntegrationSettings.fetch(:gemini_api_key)
        end
      end

      def configure_openai(config)
        api_key, base_url = if vendor == "cli_proxy"
          cli_proxy_credentials
        else
          [ OpenaiEndpoint.api_key(base_url: gateway_url, api_key: llm_api_key), gateway_url.presence ]
        end
        # RubyLLM requires a nonblank key even for keyless compatible gateways.
        config.openai_api_key = api_key.presence || ("local-gateway" if base_url)
        config.openai_api_base = base_url if base_url
        gateway = @cli_proxy_identity&.fetch(:gateway)
        if gateway && !gateway.owner.system_admin? && !gateway.desktop_loopback?
          config.faraday_adapter = Collavre::CliProxy::SafeNetHttpAdapter
        end
      end

      def cli_proxy_credentials
        agent = context[:user]
        gateway = agent&.agent_gateway
        raise ArgumentError, "CLI Proxy agent has no active gateway" unless gateway&.active?

        workspace_user = cli_proxy_workspace_user(agent)
        if gateway.per_user? && workspace_user.nil?
          raise ArgumentError, "CLI Proxy per-user workspace requires a verified human principal"
        end
        workspace_user = nil if gateway.shared?
        workspace = Collavre::AgentWorkspace.resolve!(agent: agent, user: workspace_user)
        gateway = workspace.agent_gateway
        @cli_proxy_identity = { gateway: gateway, workspace: workspace }
        [ gateway.completion_key, gateway.completion_base_url ]
      end

      def cli_proxy_workspace_user(agent)
        return context[:workspace_user] if context.key?(:workspace_user)

        comment_user = context[:comment]&.user
        (comment_user unless comment_user&.ai_user?) || agent.creator
      end
    end
  end
end
