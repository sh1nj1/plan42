# frozen_string_literal: true

module Collavre
  # Operator-published blobs: served publicly from /public-assets even though
  # no publicly shared creative holds them (e.g. landing-page media). Driven by
  # `rake collavre:public_assets:{publish,unpublish,publish_landing}`.
  module PublicAssetAllowlist
    SIGNED_ID_PATTERN = %r{/public-assets/blobs/([^/?#"\s]+)/}

    module_function

    # Returns the blobs that were found and published.
    def publish!(signed_ids)
      blobs_for(signed_ids).each { |blob| write_flag(blob, true) }
    end

    # Unpublishing also evicts the CDN copy.
    def unpublish!(signed_ids)
      blobs_for(signed_ids).each do |blob|
        write_flag(blob, nil)
        Collavre::CdnInvalidation.invalidate_blob(blob)
      end
    end

    # Signed ids of the /public-assets media referenced by the landing locales.
    def landing_signed_ids
      Dir[Collavre::Engine.root.join("config/locales/landing.*.yml")].flat_map do |path|
        File.read(path).scan(SIGNED_ID_PATTERN).flatten
      end.uniq
    end

    def blobs_for(signed_ids)
      Array(signed_ids).filter_map { |signed_id| ActiveStorage::Blob.find_signed(signed_id) }
    end

    # update_column and the row lock: see CdnInvalidation.mark_publicly_cached.
    def write_flag(blob, value)
      blob.with_lock do
        metadata = blob.metadata.except(Collavre::BlobAccess::PUBLIC_METADATA_KEY)
        metadata[Collavre::BlobAccess::PUBLIC_METADATA_KEY] = true if value
        blob.update_column(:metadata, metadata)
      end
    end
  end
end
