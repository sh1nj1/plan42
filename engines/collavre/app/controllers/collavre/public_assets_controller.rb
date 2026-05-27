# frozen_string_literal: true

module Collavre
  # Serves ActiveStorage blobs through a CDN-friendly path:
  #   /public-assets/blobs/:signed_id/*filename
  #
  # The signed_id is the only capability — no auth required. This makes the URL
  # safe to embed in landing pages and other publicly-rendered HTML. CloudFront
  # caches by full URL, so rotating signed_id (re-attach) invalidates effectively.
  class PublicAssetsController < ActionController::Base
    PUBLIC_CACHE_CONTROL = "public, max-age=31536000, immutable"

    def show
      blob = ActiveStorage::Blob.find_signed!(params[:signed_id])
      response.headers["Cache-Control"] = PUBLIC_CACHE_CONTROL
      response.headers["Content-Type"] = blob.content_type if blob.content_type.present?
      response.headers["Content-Disposition"] =
        ActionDispatch::Http::ContentDisposition.format(
          disposition: "inline",
          filename: blob.filename.sanitized
        )
      send_data blob.download, type: blob.content_type, disposition: "inline"
    rescue ActiveSupport::MessageVerifier::InvalidSignature, ActiveRecord::RecordNotFound
      head :not_found
    end
  end
end
