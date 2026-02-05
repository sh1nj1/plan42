module CollavreGithub
  class ApplicationController < ::ApplicationController
    private

    def github_webhook_url
      CollavreGithub::Engine.routes.url_helpers.webhooks_url(
        Rails.application.config.action_mailer.default_url_options
      )
    end
  end
end
