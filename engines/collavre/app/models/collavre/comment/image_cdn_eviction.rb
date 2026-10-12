# frozen_string_literal: true

module Collavre
  class Comment
    # Becoming private, or moving to another creative, can hide a comment's
    # images from anonymous readers; evict any copy /public-assets already
    # cached publicly so the CDN stops serving it.
    module ImageCdnEviction
      extend ActiveSupport::Concern

      included do
        after_update_commit :invalidate_public_image_cache, if: :image_visibility_changed?
      end

      private

      def image_visibility_changed?
        saved_change_to_private? || saved_change_to_creative_id?
      end

      def invalidate_public_image_cache
        images.blobs.each { |blob| CdnInvalidation.invalidate_blob(blob) }
      end
    end
  end
end
