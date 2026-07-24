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
  end
end
