# frozen_string_literal: true

module Collavre
  # Serves ActiveStorage blobs through a CDN-friendly path:
  #   /public-assets/blobs/:signed_id/*filename
  #
  # The signed_id identifies the blob; it is not a capability. Only a blob that
  # is readable anonymously (attached to a publicly shared creative, an avatar,
  # ...) is streamed here with a public Cache-Control so CloudFront can cache it.
  # Every other blob is redirected, uncached, to the ActiveStorage proxy route,
  # which authorizes the viewer on each request (Collavre::ActiveStorageAccess).
  # Existing descriptions keep their /public-assets URLs and stay working for
  # viewers who may read them.
  class PublicAssetsController < ActionController::Base
    include ActiveStorage::SetCurrent
    include ActiveStorage::Streaming
    include Collavre::OriginVerification
    include Collavre::BlobAccessControl

    # Browsers revalidate hourly; CloudFront keeps a day at most. Deleting a
    # blob or revoking a public share invalidates CloudFront explicitly
    # (Collavre::CdnInvalidation), and s-maxage bounds anything that slips past.
    PUBLIC_CACHE_CONTROL = "public, max-age=3600, s-maxage=86400"

    before_action :verify_cloudfront_origin!

    def show
      blob = ActiveStorage::Blob.find_signed!(params[:signed_id])
      return redirect_to_authorized_path(blob) unless blob_readable?(blob, user: nil)

      # Re-check after marking so an unpublish or share revoke that landed since
      # the first check is not served (and CDN-cached) as public. Only CDN
      # misses reach here, so the extra reload is cheap.
      Collavre::CdnInvalidation.mark_publicly_cached(blob)
      return redirect_to_authorized_path(blob) unless blob_readable?(blob.reload, user: nil)

      response.headers["Cache-Control"] = PUBLIC_CACHE_CONTROL
      send_blob_stream blob, disposition: "inline"
    rescue ActiveSupport::MessageVerifier::InvalidSignature, ActiveRecord::RecordNotFound
      head :not_found
    end

    private

    # The decision above never depends on the viewer, so the redirect itself is
    # identical for everyone; no-store keeps the CDN from pinning it once the
    # blob becomes public.
    def redirect_to_authorized_path(blob)
      response.headers["Cache-Control"] = PRIVATE_CACHE_CONTROL
      redirect_to authorized_blob_url(blob), allow_other_host: true
    end

    # With PUBLIC_ASSETS_HOST the request may have arrived on a separate CDN
    # domain that never sees the session cookie, so send the browser back to the
    # app host (DEFAULT_URL_HOST). Otherwise a path keeps it on the host it came
    # from.
    def authorized_blob_url(blob)
      helpers = Rails.application.routes.url_helpers
      url_options = Rails.application.routes.default_url_options
      if Collavre::IntegrationSettings.fetch(:public_assets_host).blank? || url_options[:host].blank?
        return helpers.rails_storage_proxy_path(blob, only_path: true)
      end

      helpers.rails_storage_proxy_url(blob, **url_options)
    end
  end
end
