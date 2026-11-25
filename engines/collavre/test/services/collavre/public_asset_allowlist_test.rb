# frozen_string_literal: true

require "test_helper"
require Collavre::Engine.root.join("db/migrate/20261012000001_publish_landing_public_assets")

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

    # ActiveStorage's analyzer writes back a metadata snapshot read before a
    # slow analysis; that must not change the publish flag either way.
    test "a stale blob metadata write neither revokes nor restores the publish flag" do
      stale = ActiveStorage::Blob.find(@blob.id)
      PublicAssetAllowlist.publish!([ @blob.signed_id ])
      stale.update!(metadata: stale.metadata.merge("analyzed" => true))
      assert public?(@blob)

      stale = ActiveStorage::Blob.find(@blob.id)
      PublicAssetAllowlist.unpublish!([ @blob.signed_id ])
      stale.update!(metadata: stale.metadata.merge("analyzed" => true))
      assert_not public?(@blob)
    end

    test "write! rejects unknown flags" do
      assert_raises(ArgumentError) { BlobAccessFlag.write!(@blob.id, :metadata, true) }
    end
  end
end
