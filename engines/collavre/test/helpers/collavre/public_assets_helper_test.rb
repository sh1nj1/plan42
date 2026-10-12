# frozen_string_literal: true

require "test_helper"

module Collavre
  class PublicAssetsHelperTest < ActionView::TestCase
    include PublicAssetsHelper

    setup do
      @user = users(:one)
      Current.user = @user
      @creative = Creative.create!(description: "<p>x</p>", user: @user)
      @creative.files.attach(io: StringIO.new("x"), filename: "x.txt", content_type: "text/plain")
      @blob = @creative.files.first.blob
    end

    teardown { Current.user = nil }

    test "uses PUBLIC_ASSETS_HOST when set" do
      ENV["PUBLIC_ASSETS_HOST"] = "https://cdn.example.com"
      url = public_asset_url(@blob)
      assert_match %r{\Ahttps://cdn\.example\.com/public-assets/blobs/[^/]+/x\.txt\z}, url
    ensure
      ENV.delete("PUBLIC_ASSETS_HOST")
    end

    test "falls back to relative path when host not set" do
      ENV.delete("PUBLIC_ASSETS_HOST")
      url = public_asset_url(@blob)
      assert_match %r{\A/public-assets/blobs/[^/]+/x\.txt\z}, url
    end

    test "attachment access URL keeps the CDN URL for public blobs" do
      perform_enqueued_jobs { CreativeShare.create!(creative: @creative, user: nil, permission: :read) }

      assert_equal public_asset_url(@blob), attachment_access_url(@blob)
    end

    test "attachment access URL points private blobs at the authorized app-host route" do
      ENV["PUBLIC_ASSETS_HOST"] = "https://cdn.example.com"
      Rails.application.routes.stub(:default_url_options, { host: "app.example.com", protocol: "https" }) do
        assert_match %r{\Ahttps://app\.example\.com/rails/active_storage/blobs/proxy/[^/]+/x\.txt\z},
          attachment_access_url(@blob)
      end
      Rails.application.routes.stub(:default_url_options, {}) do
        assert_match %r{\A/rails/active_storage/blobs/proxy/[^/]+/x\.txt\z}, attachment_access_url(@blob)
      end
    ensure
      ENV.delete("PUBLIC_ASSETS_HOST")
    end
  end
end
