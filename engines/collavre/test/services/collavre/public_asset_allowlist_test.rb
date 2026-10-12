# frozen_string_literal: true

require "test_helper"
require Collavre::Engine.root.join("db/migrate/20261012000000_publish_landing_public_assets")

module Collavre
  class PublicAssetAllowlistTest < ActiveSupport::TestCase
    setup do
      @blob = ActiveStorage::Blob.create_and_upload!(io: StringIO.new("x"), filename: "launch.mp4", content_type: "video/mp4")
    end

    def public?(blob)
      BlobAccess.new(blob.reload, user: nil).readable?
    end

    test "publish makes an unattached blob public and ignores unknown signed ids" do
      assert_not public?(@blob)

      published = PublicAssetAllowlist.publish!([ @blob.signed_id, "not-a-signed-id" ])

      assert_equal [ @blob ], published
      assert public?(@blob)
    end

    test "unpublish removes the flag and invalidates the CDN copy" do
      PublicAssetAllowlist.publish!([ @blob.signed_id ])
      invalidated = []

      CdnInvalidation.stub(:invalidate_blob, ->(blob) { invalidated << blob }) do
        PublicAssetAllowlist.unpublish!([ @blob.signed_id ])
      end

      assert_not public?(@blob)
      assert_equal [ @blob ], invalidated
    end

    test "landing signed ids come from the landing locales" do
      ids = PublicAssetAllowlist.landing_signed_ids

      assert_equal 8, ids.size
      assert(ids.all? { |id| id.include?("--") })
    end

    test "the landing migration publishes landing blobs present in this database" do
      PublicAssetAllowlist.stub(:landing_signed_ids, [ @blob.signed_id ]) do
        PublishLandingPublicAssets.new.up
      end

      assert public?(@blob)
      assert_nothing_raised { PublishLandingPublicAssets.new.down }
    end

    test "direct-upload clients cannot set server-owned metadata" do
      keys = ActiveStorageAccess::UploaderMetadata::SERVER_OWNED_KEYS

      assert_includes keys, BlobAccess::PUBLIC_METADATA_KEY
      assert_includes keys, CdnInvalidation::PUBLICLY_CACHED_METADATA_KEY
    end
  end
end
