# frozen_string_literal: true

module Collavre
  module PublicAssetsHelper
    # Returns a URL for serving an ActiveStorage blob through the public-assets
    # proxy. When PUBLIC_ASSETS_HOST is set (e.g. CloudFront domain) the URL is
    # absolute; otherwise relative so the browser uses the current host.
    def public_asset_url(blob)
      path = "/public-assets/blobs/#{blob.signed_id}/#{blob.filename.sanitized}"
      host = ENV["PUBLIC_ASSETS_HOST"].presence
      host ? "#{host.chomp('/')}#{path}" : path
    end
  end
end
