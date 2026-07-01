# frozen_string_literal: true

module CollavreLinear
  class ApplicationController < ::ApplicationController
    private

    def linear_webhook_url
      CollavreLinear::Engine.routes.url_helpers.webhook_url(
        Rails.application.config.action_mailer.default_url_options
      )
    end
  end
end
