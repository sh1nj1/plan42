# frozen_string_literal: true

module Collavre
  module Tools
    # Shared plumbing for the collavre_source_* tools. They expose the running
    # app's code, so they are restricted to the Kollavy system agent: the
    # declared allowed_user_emails hides them from every other user's tool list
    # (McpService.filter_tools / McpToolAccess), and authorize_source_access!
    # refuses a direct call that got past discovery anyway.
    module SourceToolSupport
      def self.included(base)
        base.extend(ClassMethods)
      end

      module ClassMethods
        def user_permitted?(user)
          Collavre::Kollavy::Identity.agent?(user)
        end

        def allowed_user_emails
          [ Collavre::Kollavy::EMAIL ]
        end
      end

      private

      def with_source_access
        user = Current.user
        unless Collavre::McpToolRegistry.user_permitted?(self.class.tool_metadata[:name], user)
          return { error: I18n.t("collavre.mcp_tools.unavailable") }
        end

        yield SourceBrowser.new
      rescue SourceBrowser::AccessDenied, ArgumentError => e
        { error: e.message }
      end
    end
  end
end
