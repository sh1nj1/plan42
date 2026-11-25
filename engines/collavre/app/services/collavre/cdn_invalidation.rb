# frozen_string_literal: true

module Collavre
  # Removes /public-assets responses from CloudFront when the bytes behind them
  # must stop being served: a public blob is detached or purged, or a public
  # share is revoked. Without this, a cached public copy outlives the blob for
  # the full s-maxage.
  #
  # Only blobs that /public-assets actually served publicly carry the marker,
  # so private blobs (never cached by the CDN) cost no invalidation requests.
  # A no-op unless CLOUDFRONT_DISTRIBUTION_ID is configured.
  module CdnInvalidation
    ALL_PUBLIC_ASSETS_PATH = "/public-assets/*"

    module_function

    def distribution_id
      Collavre::IntegrationSettings.fetch(:cloudfront_distribution_id).presence
    end

    def enabled?
      distribution_id.present?
    end

    # The marker is a separate row written atomically (BlobAccessFlag), so it
    # can neither restore a concurrently revoked publish flag nor be erased by
    # ActiveStorage rewriting the blob metadata.
    def mark_publicly_cached(blob)
      return if publicly_cached?(blob)

      Collavre::BlobAccessFlag.write!(blob.id, :cdn_public, true)
    end

    def publicly_cached?(blob)
      Collavre::BlobAccessFlag.set?(blob.id, :cdn_public)
    end

    def blob_paths(blob)
      [ "/public-assets/blobs/#{blob.signed_id}/*" ]
    end

    def invalidate_blob(blob)
      return unless blob && publicly_cached?(blob)

      enqueue(blob_paths(blob))
    end

    # For attachment rows removed with delete/delete_all, which skip the
    # attachment invalidation callback; a blob still attached elsewhere is
    # never purged either.
    def invalidate_blob_ids(blob_ids)
      ActiveStorage::Blob.where(id: blob_ids).find_each { |blob| invalidate_blob(blob) }
    end

    # Which blobs a revoked share exposed is not tracked per subtree, and the
    # revoke is rare, so flush the whole /public-assets behavior.
    def invalidate_all_public_assets
      enqueue([ ALL_PUBLIC_ASSETS_PATH ])
    end

    def enqueue(paths)
      return unless enabled?

      Collavre::CdnInvalidationJob.perform_later(paths)
    end
  end
end
