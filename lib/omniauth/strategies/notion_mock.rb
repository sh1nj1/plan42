require "omniauth"

module OmniAuth
  module Strategies
    # Development stand-in for Strategies::Notion.
    #
    # It exists so that mocking Notion does not require
    # OmniAuth.config.test_mode, which is global: switching it on for Notion
    # also routes a really-configured GitHub or Google through the mock path, so
    # a developer who mocks the one integration they have no credentials for
    # loses the ones they do.
    #
    # Registering it also gives /auth/notion an owner. The app declares only the
    # callback route, so with no :notion strategy in the middleware stack the
    # request phase is not OmniAuth's at all — the modal's POST 404s and no mock
    # login can happen, test_mode or not.
    class NotionMock
      include OmniAuth::Strategy

      option :name, "notion"

      # There is no provider to redirect to, so hand the browser straight back
      # to the callback — where a real round trip would have returned it.
      # Strategies::Notion stashes the popup flag on the way out; the callback
      # template reads it, so the mock has to stash it too.
      def request_phase
        session[:oauth_popup] = request.params["popup"] == "true"
        redirect callback_url
      end

      # One fixed workspace identity for every browser. NotionAuthController
      # scopes this uid to the signed-in user before it touches the database:
      # notion_accounts.notion_uid is uniquely indexed and holds one row per
      # user, so a shared uid would let the second developer to connect take
      # over the first one's account.
      uid { "notion-dev-user-001" }

      info do
        { name: "Dev Workspace", workspace_name: "Dev Workspace" }
      end

      credentials { { token: "fake-notion-dev-token" } }
    end
  end
end
