# frozen_string_literal: true

module Collavre
  module PublicAssetsHelper
    # Returns a URL for serving an ActiveStorage blob through the public-assets
    # proxy. When PUBLIC_ASSETS_HOST is set (e.g. CloudFront domain) the URL is
    # absolute; otherwise relative so the browser uses the current host.
    def public_asset_url(blob)
      path = "/public-assets/blobs/#{blob.signed_id}/#{blob.filename.sanitized}"
      host = Collavre::IntegrationSettings.fetch(:public_assets_host)
      host ? "#{host.chomp('/')}#{path}" : path
    end

    # URL for API, MCP and agent clients. A private blob would be redirected
    # from /public-assets to the app host, and clients drop the Authorization
    # header on a cross-host redirect, so link the authorized proxy route on the
    # app host directly. Public blobs keep the cacheable CDN URL.
    def attachment_access_url(blob)
      return public_asset_url(blob) if Collavre::BlobAccess.new(blob, user: nil).readable?

      helpers = Rails.application.routes.url_helpers
      url_options = Rails.application.routes.default_url_options
      return helpers.rails_storage_proxy_path(blob, only_path: true) if url_options[:host].blank?

      helpers.rails_storage_proxy_url(blob, **url_options)
    end
  end
end
