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

      class_methods do
        # Bulk relocations (update_all) skip the callback above, so callers
        # evict the moved comments' images explicitly. The job waits for commit.
        def invalidate_public_images_of(comments)
          ActiveStorage::Blob.joins(:attachments)
            .where(active_storage_attachments: { record_type: name, name: "images", record_id: comments.select(:id) })
            .find_each { |blob| CdnInvalidation.invalidate_blob(blob) }
        end
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
