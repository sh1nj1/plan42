# frozen_string_literal: true

module CollavreLinear
  class ApplicationController < ::ApplicationController
    private

    # Public HTTPS URL Linear will POST inbound webhook deliveries to. The
    # engine is `isolate_namespace`d and mounted at MOUNT_PATH (/linear), so we
    # fold the mount prefix back in explicitly via `script_name:` — the
    # generated URL MUST be the fully mounted /linear/webhook, never the
    # engine-internal /webhook, or Linear delivers to a 404 and inbound sync
    # never runs.
    def linear_webhook_url
      CollavreLinear::Engine.routes.url_helpers.webhook_url(
        Rails.application.config.action_mailer.default_url_options.merge(
          script_name: CollavreLinear::Engine::MOUNT_PATH
        )
      )
    end
  end
end
