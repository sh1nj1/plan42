# frozen_string_literal: true

require "sorbet-runtime"

module Collavre
  module MetaToolAccess
    extend T::Sig

    sig do
      params(action: String, tool_name: T.nilable(String), query: T.nilable(String),
             arguments: T.nilable(T::Hash[T.untyped, T.untyped])).returns(T::Hash[Symbol, T.untyped])
    end
    def call(action:, tool_name: nil, query: nil, arguments: nil)
      Collavre::McpToolRegistrar.synchronize do
        Collavre::McpToolAccess.refresh
        if %w[get run].include?(action) && !Collavre::McpToolAccess.allowed?(tool_name)
          return { error: I18n.t("collavre.mcp_tools.unavailable") }
        end

        result = super
        result[:tools] = Collavre::McpService.filter_tools(result[:tools], Collavre::Current.user) if result[:tools]
        result
      end
    end
  end
end

Rails.application.config.to_prepare do
  ::Tools::MetaToolService.prepend(Collavre::MetaToolAccess) unless ::Tools::MetaToolService < Collavre::MetaToolAccess
end
